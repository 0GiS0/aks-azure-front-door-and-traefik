# Variables
RESOURCE_GROUP="aks-afd-and-traefik-ic"
LOCATION="westeurope"
AKS_CLUSTER_NAME="aks-cluster"
AKS_VNET="aks-vnet"
AKS_SUBNET="aks-subnet"
PLS_SUBNET="pls-subnet"

# Create a resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create a vnet for the cluster
az network vnet create \
--resource-group $RESOURCE_GROUP \
--name $AKS_VNET \
--address-prefixes 10.0.0.0/8 \
--subnet-name $AKS_SUBNET \
--subnet-prefixes 10.10.0.0/16

# Create a subnet for the Private Links
az network vnet subnet create \
--resource-group $RESOURCE_GROUP \
--vnet-name $AKS_VNET \
--name $PLS_SUBNET \
--address-prefixes 10.20.0.0/24

# Create user identity for the AKS cluster
az identity create --name $AKS_CLUSTER_NAME-identity --resource-group $RESOURCE_GROUP
IDENTITY_ID=$(az identity show --name $AKS_CLUSTER_NAME-identity --resource-group $RESOURCE_GROUP --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $AKS_CLUSTER_NAME-identity --resource-group $RESOURCE_GROUP --query clientId -o tsv)

# Get VNET id
VNET_ID=$(az network vnet show --resource-group $RESOURCE_GROUP --name $AKS_VNET --query id -o tsv)

# Assign Network Contributor role to the user identity
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $VNET_ID --role "Network Contributor"
# Permission granted to your cluster's managed identity used by Azure may take up 60 minutes to populate.

# Get roles assigned to the user identity
az role assignment list --assignee $IDENTITY_CLIENT_ID --all -o table

AKS_SUBNET_ID=$(az network vnet subnet show --resource-group $RESOURCE_GROUP --vnet-name $AKS_VNET --name $AKS_SUBNET --query id -o tsv)

# Create an AKS cluster
time az aks create \
--resource-group $RESOURCE_GROUP \
--node-vm-size Standard_B4ms \
--name $AKS_CLUSTER_NAME \
--enable-managed-identity \
--vnet-subnet-id $AKS_SUBNET_ID \
--assign-identity $IDENTITY_ID \
--generate-ssh-keys

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME

# Install Traefik

# Create a cluster role
kubectl apply -f - <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: traefik-role

rules:
  - apiGroups:
      - ""
    resources:
      - services
      - endpoints
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses
      - ingressclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
EOF

# Crete a service account
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-account
EOF

# Create a cluster role binding
kubectl apply -f - <<EOF
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: traefik-role-binding

roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-role
subjects:
  - kind: ServiceAccount
    name: traefik-account
    namespace: default # Using "default" because we did not specify a namespace when creating the ClusterAccount.
EOF

# Create a deployment with traefik
kubectl apply -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: traefik-deployment
  labels:
    app: traefik

spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik-account
      containers:
        - name: traefik
          image: traefik:v2.9
          args:
            - --api.insecure
            - --providers.kubernetesingress
          ports:
            - name: web
              containerPort: 80
            - name: dashboard
              containerPort: 8080
EOF

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create services
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: traefik-dashboard-service
spec:
  type: LoadBalancer
  ports:
    - port: 8080
      targetPort: dashboard
  selector:
    app: traefik
---
apiVersion: v1
kind: Service
metadata:
  name: traefik-web-service
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-pls-create: "true"
    service.beta.kubernetes.io/azure-pls-name: traefik-lb-private-link 
    service.beta.kubernetes.io/azure-pls-ip-configuration-subnet: "$PLS_SUBNET" # Private Link subnet name
    service.beta.kubernetes.io/azure-pls-ip-configuration-ip-address-count: "1"
    service.beta.kubernetes.io/azure-pls-ip-configuration-ip-address: 10.20.0.10
    service.beta.kubernetes.io/azure-pls-visibility: "*"    
spec:
  type: LoadBalancer
  ports:
    - targetPort: web
      port: 80
  selector:
    app: traefik
EOF

kubectl get service -w

# Deploy whoami
kubectl apply -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: whoami
  labels:
    app: whoami

spec:
  replicas: 1
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - name: web
              containerPort: 80
EOF

# And it's service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: whoami

spec:
  ports:
    - name: web
      port: 80
      targetPort: web

  selector:
    app: whoami
EOF

# Create traefik ingress
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami-ingress
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: whoami
            port:
              name: web
EOF

# Check traefik logs
kubectl logs -f $(kubectl get pods -l app=traefik -o jsonpath='{.items[0].metadata.name}')

# Test access whoami internally
kubectl run -it --rm aks-ingress-test --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11
apt-get update && apt-get install -y curl
# Directly to the service
curl http://whoami
# Through the ingress
curl http:/traefik-web-service/
exit

##### Test private link service from a vm #####
VM_SUBNET="vm-subnet"

az network vnet subnet create \
--resource-group $RESOURCE_GROUP \
--vnet-name $AKS_VNET \
--name $VM_SUBNET \
--address-prefixes 10.30.0.0/24

# Get AKS node group
AKS_RESOURCE_GROUP=$(az aks show -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME --query nodeResourceGroup -o tsv)

PLS_RESOURCE_ID=$(az network private-link-service show -g $AKS_RESOURCE_GROUP -n traefik-lb-private-link --query "id" -o tsv)

# Create private endpoint
az network private-endpoint create \
--resource-group $RESOURCE_GROUP \
--name private-endpoint-for-the-aks-pls \
--vnet-name $AKS_VNET \
--subnet $VM_SUBNET \
--private-connection-resource-id $PLS_RESOURCE_ID \
--connection-name connection-for-my-vm \
--location $LOCATION

# Create a virtual machine
az vm create \
--resource-group $RESOURCE_GROUP \
--name jumpbox-vm \
--image UbuntuLTS \
--admin-username azureuser \
--admin-password AzurePassword1234 \
--size Standard_B4ms \
--vnet-name $AKS_VNET \
--subnet $VM_SUBNET 

# Get the VM public IP address
VM_IP=$(az vm list-ip-addresses --resource-group $RESOURCE_GROUP --name jumpbox-vm --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress' -o tsv)

# Using private endpoint to call the aks service
# Get network interface for the private endpoint
PRIVATE_ENDPOINT_NIC_ID=$(az network private-endpoint show -g $RESOURCE_GROUP -n private-endpoint-for-the-aks-pls --query "networkInterfaces[0].id" -o tsv)
# Get the private endpoint IP
PRIVATE_ENDPOINT_IP=$(az network nic show --ids $PRIVATE_ENDPOINT_NIC_ID --query "ipConfigurations[0].privateIPAddress" -o tsv)

echo $PRIVATE_ENDPOINT_IP

# TODO: Create a Azure DNS private zone and associate the private endpoint
# https://docs.microsoft.com/en-us/azure/dns/private-dns-getstarted-cli#create-a-private-dns-zone

# Connect to the vm via ssh
ssh azureuser@$VM_IP
curl http:/10.30.0.4
exit


# Get ingress IP
TRAEFIK_INGRESS_CONTROLLER_IP=$(kubectl get svc traefik-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

AZURE_FRONT_DOOR_PROFILE_NAME="aks-azure-front-door-and-traefik"

# Deploy Azure Front Door
az afd profile create \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--resource-group $RESOURCE_GROUP \
--sku Premium_AzureFrontDoor

# Add an endpoint
ENDPOINT_NAME="aks-traefik-endpoint"

az afd endpoint create \
--resource-group $RESOURCE_GROUP \
--endpoint-name $ENDPOINT_NAME \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--enabled-state Enabled

# Create an origin group
# origin group that will define the traffic and expected responses for your app instances. Origin groups also define how origins should be evaluated by health probes, which you'll also define in this step.
AFD_ORIGIN_GROUP_NAME="aks-origin-group"

az afd origin-group create \
--resource-group $RESOURCE_GROUP \
--origin-group-name $AFD_ORIGIN_GROUP_NAME \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--probe-request-type GET \
--probe-protocol Http \
--probe-interval-in-seconds 60 \
--probe-path / \
--sample-size 4 \
--successful-samples-required 3 \
--additional-latency-in-milliseconds 50

# Get the alias for the private link service
AKS_RESOURCE_GROUP=$(az aks show -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME --query nodeResourceGroup -o tsv)
PRIVATE_LINK_ALIAS=$(az network private-link-service show -g $AKS_RESOURCE_GROUP -n traefik-lb-private-link --query "alias" -o tsv)
PLS_RESOURCE_ID=$(az network private-link-service show -g $AKS_RESOURCE_GROUP -n traefik-lb-private-link --query "id" -o tsv)

az afd origin create \
--resource-group $RESOURCE_GROUP \
--origin-group-name $AFD_ORIGIN_GROUP_NAME \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--origin-name aks-traefik-lb-endpoint \
--host-name  $PRIVATE_LINK_ALIAS \
--origin-host-header "" \
--http-port 80 \
--https-port 443 \
--enable-private-link true \
--private-link-location $LOCATION \
--private-link-resource $PLS_RESOURCE_ID \
--private-link-request-message 'Please approve this request' \
--enabled-state Enabled

# Approve the private link request
CONNECTION_RESOURCE_ID=$(az network private-endpoint-connection list --name traefik-lb-private-link --resource-group $AKS_RESOURCE_GROUP --type Microsoft.Network/privateLinkServices --query "[0].id" -o tsv)
az network private-endpoint-connection approve --id $CONNECTION_RESOURCE_ID

# Add a route
AFD_ROUTE_NAME="traefik-route"

az afd route create \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--forwarding-protocol MatchRequest \
--route-name $AFD_ROUTE_NAME \
--https-redirect Disabled \
--origin-group $AFD_ORIGIN_GROUP_NAME \
--supported-protocols Http \
--link-to-default-domain Enabled

AFD_HOST_NAME=$(az afd endpoint show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --endpoint-name $ENDPOINT_NAME --query "hostName" -o tsv)

echo http://$AFD_HOST_NAME/


################################################
##### Add custom domains to the endpoint #######
################################################
SUBDOMAIN="www"

CUSTOM_DOMAIN_NAME_ONE="domaingis.com"
CUSTOM_DOMAIN_ONE_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$HOST_NAME

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

CUSTOM_DOMAIN_NAME_TWO="azuredemo.es"
CUSTOM_DOMAIN_TWO_WITH_DASHES="$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO" | sed 's/\./-/g')"

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

CUSTOM_DOMAIN_NAME_THREE="matrixapp.es"
CUSTOM_DOMAIN_THREE_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

# Add a custom domain to the route
az afd route update \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME \
--custom-domains $CUSTOM_DOMAIN_ONE_WITH_DASHES $CUSTOM_DOMAIN_TWO_WITH_DASHES $CUSTOM_DOMAIN_THREE_WITH_DASHES

# Check custom domains for a route
az afd route show \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME

# Test the custom domains
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE/
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO/
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE/

#### api subdomain ####

SUBDOMAIN="api"

CUSTOM_DOMAIN_NAME_ONE="domaingis.com"
CUSTOM_DOMAIN_ONE_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_NAME_ONE \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$HOST_NAME

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

CUSTOM_DOMAIN_NAME_TWO="azuredemo.es"
CUSTOM_DOMAIN_TWO_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

CUSTOM_DOMAIN_NAME_THREE="matrixapp.es"
CUSTOM_DOMAIN_THREE_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."


# Get all custom domains name configured in a route
CUSTOM_DOMAINS_ID=$(az afd route show \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME \
--query "customDomains[].id" -o tsv)

# Get the custom domain names from the IDs (This doesn't work)
CUSTOM_DOMAINS_NAMES=$(az afd custom-domain show \
--ids $CUSTOM_DOMAINS_ID \
--query "[].name" -o tsv | tr '\n' ' ')

# Add a custom domain to the route
az afd route update \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME \
--custom-domains $(echo $CUSTOM_DOMAINS_NAMES) $CUSTOM_DOMAIN_ONE_WITH_DASHES $CUSTOM_DOMAIN_TWO_WITH_DASHES $CUSTOM_DOMAIN_THREE_WITH_DASHES

# Test the custom domains
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE/
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO/
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE/

#### dev subdomain ####

SUBDOMAIN="dev"

CUSTOM_DOMAIN_NAME_ONE="domaingis.com"
CUSTOM_DOMAIN_ONE_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_ONE_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$HOST_NAME

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

CUSTOM_DOMAIN_NAME_TWO="azuredemo.es"
CUSTOM_DOMAIN_TWO_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_TWO_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

CUSTOM_DOMAIN_NAME_THREE="thedev.es"
CUSTOM_DOMAIN_THREE_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE" | sed 's/\./-/g')

# Create a custom domain
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_THREE_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."


# Get all custom domains name configured in a route
CUSTOM_DOMAINS_ID=$(az afd route show \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME \
--query "customDomains[].id" -o tsv)

# Get the custom domain names from the IDs (This doesn't work)
CUSTOM_DOMAINS_NAMES=$(az afd custom-domain show \
--ids $CUSTOM_DOMAINS_ID \
--query "[].name" -o tsv | tr '\n' ' ')

# Add a custom domain to the route
az afd route update \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME \
--custom-domains $(echo $CUSTOM_DOMAINS_NAMES) $CUSTOM_DOMAIN_ONE_WITH_DASHES $CUSTOM_DOMAIN_TWO_WITH_DASHES $CUSTOM_DOMAIN_THREE_WITH_DASHES

# Test the custom domains
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_ONE/
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_TWO/
curl http://$SUBDOMAIN.$CUSTOM_DOMAIN_NAME_THREE/


################################################
########### Check security policies ############
################################################
# A security policy includes a web application firewall (WAF) policy and one or more domains to provide centralized protection for your web applications.
# https://docs.microsoft.com/en-us/azure/frontdoor/front-door-security-policies


#### WAF Policy for www ####

# Create a root waf policy
WWW_WAF_POLICY_NAME="wwwWAFPolicy"

# Create a Azure Front Door policy
az network front-door waf-policy create \
--resource-group $RESOURCE_GROUP \
--name $WWW_WAF_POLICY_NAME \
--mode Prevention \
--sku Premium_AzureFrontDoor

# Add a managed rule to the WAF policy
az network front-door waf-policy managed-rules add \
--resource-group $RESOURCE_GROUP \
--policy-name $WWW_WAF_POLICY_NAME \
--type Microsoft_DefaultRuleSet \
--version 2.1 \
--action Block

# Create custom rule
az network front-door waf-policy rule create \
--resource-group $RESOURCE_GROUP \
--policy-name $WWW_WAF_POLICY_NAME \
--name "wwwcustomrule" \
--priority 1 \
--rule-type MatchRule \
--action Block \
--defer

# Add a condition to the custom rule
az network front-door waf-policy rule match-condition add \
--match-variable QueryString \
--operator Contains \
--values "blockme" \
--name wwwcustomrule \
--resource-group $RESOURCE_GROUP \
--policy-name $WWW_WAF_POLICY_NAME

# Check custom rules
az network front-door waf-policy rule list \
--resource-group $RESOURCE_GROUP \
--policy-name $GENERAL_WAF_POLICY_NAME

# Custom error
az network front-door waf-policy update \
--resource-group $RESOURCE_GROUP \
--name $WWW_WAF_POLICY_NAME \
--custom-block-response-body $(cat custom-error/403.html | base64)



# Get the WAF policy ID
WWW_WAF_POLICY_ID=$(az network front-door waf-policy show --resource-group $RESOURCE_GROUP --name $GENERAL_WAF_POLICY_NAME --query "id" -o tsv)

# Get custom domains with www
WWW_CUSTOM_DOMAINS_ID=$(az afd custom-domain list \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--query "[?contains(hostName,'www')].id" -o tsv)

# Glue the WAF policy to the security policy
WWWW_SECURITY_POLICY_NAME="www-security-policy"
az afd security-policy create \
--security-policy-name $WWWW_SECURITY_POLICY_NAME \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--waf-policy $WWW_WAF_POLICY_ID \
--domains $(echo $WWW_CUSTOM_DOMAINS_ID | tr '\n' ' ')


#### WAF Policy for dev ####

# Create a WAF policy
DEV_WAF_POLICY_NAME="devWafPolicy"

# Create a Azure Front Door policy 
az network front-door waf-policy create \
--resource-group $RESOURCE_GROUP \
--name $DEV_WAF_POLICY_NAME \
--mode Detection \
--sku Premium_AzureFrontDoor

# Check managed rules
az network front-door waf-policy managed-rule-definition list -o table

# Add managed rules
az network front-door waf-policy managed-rules add \
--resource-group $RESOURCE_GROUP \
--policy-name $DEV_WAF_POLICY_NAME \
--type Microsoft_DefaultRuleSet \
--version 2.1 \
--action Log

# Add bot rules
az network front-door waf-policy managed-rules add \
--resource-group $RESOURCE_GROUP \
--policy-name $DEV_WAF_POLICY_NAME \
--type Microsoft_BotManagerRuleSet \
--version 1.0 \
--action Log

# Add custom rule
az network front-door waf-policy rule create \
--resource-group $RESOURCE_GROUP \
--policy-name $DEV_WAF_POLICY_NAME \
--name "devcustomrule" \
--priority 1 \
--rule-type MatchRule \
--action Log \
--defer

# Add a condition to the custom rule
az network front-door waf-policy rule match-condition add \
--match-variable QueryString \
--operator Contains \
--values "blockme" \
--name devcustomrule \
--resource-group $RESOURCE_GROUP \
--policy-name $DEV_WAF_POLICY_NAME

# Check custom rules
az network front-door waf-policy rule list \
--resource-group $RESOURCE_GROUP \
--policy-name $DEV_WAF_POLICY_NAME

# Get the WAF policy ID
DEV_WAF_POLICY_ID=$(az network front-door waf-policy show --resource-group $RESOURCE_GROUP --name $DEV_WAF_POLICY_NAME --query "id" -o tsv)

# Get custom domains with www
DEV_CUSTOM_DOMAINS_ID=$(az afd custom-domain list \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--query "[?contains(hostName,'dev')].id" -o tsv)

# Create a dev security policy
DEV_SECURITY_POLICY_NAME="dev-security-policy"

# Glue the WAF policy to the security policy
az afd security-policy create \
--security-policy-name $DEV_SECURITY_POLICY_NAME \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--waf-policy $DEV_WAF_POLICY_ID \
--domains $(echo $DEV_CUSTOM_DOMAINS_ID | tr '\n' ' ')

#### WAF Policy for api ####

# Create a root waf policy
API_WAF_POLICY_NAME="apiWAFPolicy"

# Create a Azure Front Door policy
az network front-door waf-policy create \
--resource-group $RESOURCE_GROUP \
--name $API_WAF_POLICY_NAME \
--mode Prevention \
--sku Premium_AzureFrontDoor

# Add a managed rule to the WAF policy
az network front-door waf-policy managed-rules add \
--resource-group $RESOURCE_GROUP \
--policy-name $API_WAF_POLICY_NAME \
--type Microsoft_DefaultRuleSet \
--version 2.1 \
--action Block

# Create custom rule
az network front-door waf-policy rule create \
--resource-group $RESOURCE_GROUP \
--policy-name $API_WAF_POLICY_NAME \
--name "apicustomrule" \
--priority 1 \
--rule-type MatchRule \
--action Block \
--defer

# Add a condition to the custom rule
az network front-door waf-policy rule match-condition add \
--match-variable QueryString \
--operator Contains \
--values "apiblockme" \
--name apicustomrule \
--resource-group $RESOURCE_GROUP \
--policy-name $API_WAF_POLICY_NAME

# Check custom rules
az network front-door waf-policy rule list \
--resource-group $RESOURCE_GROUP \
--policy-name $API_WAF_POLICY_NAME


# Get the WAF policy ID
API_WAF_POLICY_ID=$(az network front-door waf-policy show --resource-group $RESOURCE_GROUP --name $API_WAF_POLICY_NAME --query "id" -o tsv)

# Get custom domains with www
API_CUSTOM_DOMAINS_ID=$(az afd custom-domain list \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--query "[?contains(hostName,'api')].id" -o tsv)

# Glue the WAF policy to the security policy
API_SECURITY_POLICY_NAME="api-security-policy"
az afd security-policy create \
--security-policy-name $API_SECURITY_POLICY_NAME \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--waf-policy $API_WAF_POLICY_ID \
--domains $(echo $API_CUSTOM_DOMAINS_ID | tr '\n' ' ')

# Check all security policies
az afd security-policy list \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME -o table

#########################################################
####################### WAF tests #######################
#########################################################

AZURE_FRONT_DOOR_PROFILE_ID=$(az afd profile show \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--query "id" -o tsv)

# Create workspace for diagnostics
WORKSPACE_NAME="FrontDoorWorkspace"
WORKSPACE_ID=$(az monitor log-analytics workspace create \
--resource-group $RESOURCE_GROUP \
--workspace-name $WORKSPACE_NAME \
--query "id" -o tsv)

# Configure Diagnostic Settings for Azure Front Door
az monitor diagnostic-settings create \
--resource $AZURE_FRONT_DOOR_PROFILE_ID \
--name FrontDoorDiagnostics \
--workspace $WORKSPACE_ID \
--logs '[{"category": "FrontdoorAccessLog", "enabled": true}, {"category": "FrontdoorWebApplicationFirewallLog", "enabled": true}, {"category": "FrontDoorHealthProbeLog", "enabled": true]'

# Check diagnostic settings configuration
az monitor diagnostic-settings show \
--resource $AZURE_FRONT_DOOR_PROFILE_ID \
--name FrontDoorDiagnostics


############# devWAFPolicy #############

# SQL Injection
curl http://dev.azuredemo.es?id=1%20or%201=1

# Test custom rule
curl http://dev.azuredemo.es?id=blockme


# Get workspace GUID
WORKSPACE_GUID=$(az monitor log-analytics workspace show \
--workspace-name $WORKSPACE_NAME \
--resource-group $RESOURCE_GROUP \
--query "customerId" -o tsv)

# Get logs
az monitor log-analytics query -w $WORKSPACE_GUID --analytics-query "AzureDiagnostics | where Category == 'FrontDoorWebApplicationFirewallLog' | project requestUri_s, ruleName_s, action_s" -o table


############ wwwWAFPolicy (Prevention mode) #############

# SQL Injection
curl http://www.azuredemo.es?id=1%20or%201=1

# Test custom rule
curl http://www.azuredemo.es?id=blockme

# SQL Injection
curl http://www.domaingis.com?id=1%20or%201=1


##### apiWAFPolicy (Prevention mode) #####

# SQL Injection
curl http://api.azuredemo.es?id=1%20or%201=1


# Create Azure Storage Account
STORAGE_ACCOUNT_NAME="herostore"
az storage account create \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION

# Enable static website
az storage blob service-properties update \
--account-name $STORAGE_ACCOUNT_NAME \
--static-website

# Get static website url for custom error pages
STATIC_WEB_SITE_URL=$(az storage account show \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--query primaryEndpoints.web \
--output tsv)

# Upload custom error pages
az storage blob upload-batch \
--account-name $STORAGE_ACCOUNT_NAME \
--destination \$web \
--source images

# Deploy pod info examples
kubectl apply -f demos/

# Fix NSG for dashboard 8080
kubectl port-forward traefik-deployment-66695599d9-fltw2 8080:8080

### Limits ###
# https://learn.microsoft.com/en-us/azure/frontdoor/front-door-routing-limits
# https://github.com/MicrosoftDocs/azure-docs/blob/main/includes/front-door-limits.md#azure-front-door-standard-and-premium-tier-service-limits

