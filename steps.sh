# Variables
RESOURCE_GROUP="aks-afd-and-traefik"
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
--subnet-prefixes 10.240.0.0/24

# Create a subnet for the Private Links
az network vnet subnet create \
--resource-group $RESOURCE_GROUP \
--vnet-name $AKS_VNET \
--name $PLS_SUBNET \
--address-prefixes 10.241.0.0/24

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
az aks create \
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
    service.beta.kubernetes.io/azure-pls-ip-configuration-ip-address: 10.241.0.10
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

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dashboard-ingress
spec:
  rules:
  - http:
      paths:
      - path: /dashboard
        pathType: Prefix
        backend:
          service:
            name: traefik-dashboard-service
            port:
              number: 8080
EOF

# Check traefik logs
kubectl logs -f $(kubectl get pods -l app=traefik -o jsonpath='{.items[0].metadata.name}')

# Test access whoami internally
kubectl run -it --rm aks-ingress-test --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11
apt-get update && apt-get install -y curl
curl http://10.240.0.7
exit

##### Test private link service from a vm #####
VM_SUBNET="vm-subnet"

az network vnet subnet create \
--resource-group $RESOURCE_GROUP \
--vnet-name $AKS_VNET \
--name $VM_SUBNET \
--address-prefixes 10.242.0.0/24

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
# Connect to the vm via ssh
ssh azureuser@$VM_IP
curl http://10.240.0.7

# Use private endpoint from the vm
curl http://10.242.0.4


# Get traefik dashboard IP
TRAEFIK_DASHBOARD_IP=$(kubectl get svc traefik-dashboard-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo http://$TRAEFIK_DASHBOARD_IP:8080


# Get ingress IP
TRAEFIK_INGRESS_CONTROLLER_IP=$(kubectl get svc traefik-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

AZURE_FRONT_DOOR_PROFILE_NAME="aks-azure-front-door-and-traefik"

# Deploy Azure Front Door
az afd profile create \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--resource-group $RESOURCE_GROUP \
--sku Premium_AzureFrontDoor

# Add an endpoint
ENDPOINT_NAME="aks-endpoint"

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

#AKS resource group
AKS_RESOURCE_GROUP=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query nodeResourceGroup -o tsv)

# Get the alias for the private link service
PRIVATE_LINK_ALIAS=$(az network private-link-service show -g $AKS_RESOURCE_GROUP -n traefik-lb-private-link --query "alias" -o tsv)

az afd origin create \
--resource-group $RESOURCE_GROUP \
--origin-group-name $AFD_ORIGIN_GROUP_NAME \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--origin-name aks-traefik-lb-endpoint \
--host-name  $PRIVATE_LINK_ALIAS \
--origin-host-header $PRIVATE_LINK_ALIAS \
--http-port 80 \
--https-port 443 \
--enable-private-link true \
--private-link-location $LOCATION \
--private-link-resource $PLS_RESOURCE_ID \
--private-link-request-message 'Please approve this request' \
--enabled-state Enabled

# Approve the private link request
CONNECTION_RESOURCE_ID=$(az network private-endpoint-connection list --name traefik-lb-private-link --resource-group $AKS_RESOURCE_GROUP --type Microsoft.Network/privateLinkServices --query "[1].id" -o tsv)
az network private-endpoint-connection approve --id $CONNECTION_RESOURCE_ID

# Add a route
az afd route create \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--forwarding-protocol MatchRequest \
--route-name traefik-route \
--https-redirect Disabled \
--origin-group $AFD_ORIGIN_GROUP_NAME \
--supported-protocols Http \
--link-to-default-domain Enabled

HOST_NAME=$(az afd endpoint show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --endpoint-name $ENDPOINT_NAME --query "hostName" -o tsv)

echo http://$HOST_NAME/
echo http://$HOST_NAME/dashboard
