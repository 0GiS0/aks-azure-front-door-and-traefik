# Create a resource group
echo -e "${HIGHLIGHT}Creating the resource group '$RESOURCE_GROUP' 📦 ...${VERBOSE_COLOR}"
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create a vnet for the cluster
echo -e "${HIGHLIGHT}Creating a vnet '$AKS_VNET' 🕸️ ...${VERBOSE_COLOR}"
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
echo -e "${HIGHLIGHT}Create an identity for the cluster 🧑 ...${VERBOSE_COLOR}"

az identity create --name $AKS_CLUSTER_NAME-identity --resource-group $RESOURCE_GROUP
echo -e "${HIGHLIGHT}Waiting 60 seconds for the identity..."
sleep 60
IDENTITY_ID=$(az identity show --name $AKS_CLUSTER_NAME-identity --resource-group $RESOURCE_GROUP --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $AKS_CLUSTER_NAME-identity --resource-group $RESOURCE_GROUP --query clientId -o tsv)

# Get VNET id
VNET_ID=$(az network vnet show --resource-group $RESOURCE_GROUP --name $AKS_VNET --query id -o tsv)

# Assign Network Contributor role to the user identity
echo -e "${HIGHLIGHT}Assign roles to the identity 🎟️ ...${VERBOSE_COLOR}"
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $VNET_ID --role "Network Contributor"
# Permission granted to your cluster's managed identity used by Azure may take up 60 minutes to populate.

# Get roles assigned to the user identity
az role assignment list --assignee $IDENTITY_CLIENT_ID --all -o table

AKS_SUBNET_ID=$(az network vnet subnet show --resource-group $RESOURCE_GROUP --vnet-name $AKS_VNET --name $AKS_SUBNET --query id -o tsv)

# Create an AKS cluster
echo -e "${HIGHLIGHT}Creating the cluster $AKS_CLUSTER_NAME ☸️...${VERBOSE_COLOR}"
time az aks create \
--resource-group $RESOURCE_GROUP \
--node-vm-size Standard_B4ms \
--name $AKS_CLUSTER_NAME \
--enable-managed-identity \
--vnet-subnet-id $AKS_SUBNET_ID \
--assign-identity $IDENTITY_ID \
--generate-ssh-keys

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME  --overwrite-existing

echo -e "${HIGHLIGHT}The cluster is ready 🥳${VERBOSE_COLOR}"