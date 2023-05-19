
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

# Connect to the vm via ssh
ssh azureuser@$VM_IP
curl http:/10.30.0.4
exit
