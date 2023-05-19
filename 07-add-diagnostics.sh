echo -e "${HIGHLIGHT} First, let's create a workspace for the logs 💙...${VERBOSE_COLOR}"
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
--logs "[{category:FrontdoorAccessLog,enabled:true},{category:FrontdoorWebApplicationFirewallLog,enabled:true},{category:FrontDoorHealthProbeLog,enabled:true}]"

# Check diagnostic settings configuration
az monitor diagnostic-settings show \
--resource $AZURE_FRONT_DOOR_PROFILE_ID \
--name FrontDoorDiagnostics

echo -e "${HIGHLIGHT} Done 💙"

