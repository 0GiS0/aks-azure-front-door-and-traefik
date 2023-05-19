# Deploy Azure Front Door
echo -e "${HIGHLIGHT}Deploy Azure Front Door 🚪 ...${VERBOSE_COLOR}"

az afd profile create \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--resource-group $RESOURCE_GROUP \
--sku Premium_AzureFrontDoor

# Add an endpoint
echo "${HIGHLIGHT}Add an endpoint for the AKS ...${VERBOSE_COLOR}"

az afd endpoint create \
--resource-group $RESOURCE_GROUP \
--endpoint-name $ENDPOINT_NAME \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--enabled-state Enabled

# Create an origin group
# origin group that will define the traffic and expected responses for your app instances. 
# Origin groups also define how origins should be evaluated by health probes, which you'll also define in this step.
echo "Create an origin group...${VERBOSE_COLOR}"

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

echo -e "${HIGHLIGHT}Create an origin for that origin group...${VERBOSE_COLOR}"

az afd origin create \
--resource-group $RESOURCE_GROUP \
--origin-group-name $AFD_ORIGIN_GROUP_NAME \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--origin-name aks-traefik-lb-endpoint \
--host-name  $PRIVATE_LINK_ALIAS \
--http-port 80 \
--https-port 443 \
--enable-private-link true \
--private-link-location $LOCATION \
--private-link-resource $PLS_RESOURCE_ID \
--private-link-request-message 'Please approve this request' \
--enabled-state Enabled

# Approve the private link request
echo -e "${HIGHLIGHT}Approve the private link request from the origin${VERBOSE_COLOR}"
CONNECTION_RESOURCE_ID=$(az network private-endpoint-connection list --name traefik-lb-private-link --resource-group $AKS_RESOURCE_GROUP --type Microsoft.Network/privateLinkServices --query "[0].id" -o tsv)
az network private-endpoint-connection approve --id $CONNECTION_RESOURCE_ID

# Add a route
echo -e "${HIGHLIGHT}Add a route 🚏...${VERBOSE_COLOR}"
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

echo -e "${HIGHLIGHT}Now you have an Azure Front Door with an endpoint set${VERBOSE_COLOR}"
echo http://$AFD_HOST_NAME/
echo -e "${HIGHLIGHT}Waiting for the endpoint to be ready${VERBOSE_COLOR}"

# Loop until 200
status_code=-1
while [ $status_code != 200 ]; do
    echo -e "${HIGHLIGHT} Wait for it..."
    status_code=$(curl -s -o /dev/null -w "%{http_code}" http://$AFD_HOST_NAME/)
    if [[ $status_code != 200 ]]; then sleep 10; fi
done

curl http://$AFD_HOST_NAME/