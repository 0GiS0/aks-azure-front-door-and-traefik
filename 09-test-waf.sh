CUSTOM_DOMAIN=$1

echo "${HIGHLIGHT} Let's test ${CUSTOM_DOMAIN} 🧪! ${VERBOSE_COLOR}"

# SQL Injection
echo "SQL Injection: http://${CUSTOM_DOMAIN}?id=1%20or%201=1"
curl -I "http://${CUSTOM_DOMAIN}?id=1%20or%201=1"

# Test custom rule
echo "${VERBOSE_COLOR}Custom rule: http://${CUSTOM_DOMAIN}?id=blockme"
curl -I "http://${CUSTOM_DOMAIN}?id=blockme"

# Check custom page
echo "http://${CUSTOM_DOMAIN}?id=1%20or%201=1"

echo "${HIGHLIGHT}Check Diagnostics Logs"
# Get workspace GUID
WORKSPACE_GUID=$(az monitor log-analytics workspace show \
--workspace-name $WORKSPACE_NAME \
--resource-group $RESOURCE_GROUP \
--query "customerId" -o tsv)

# Get logs
az monitor log-analytics query -w $WORKSPACE_GUID --analytics-query "AzureDiagnostics | where Category == 'FrontDoorWebApplicationFirewallLog' | project requestUri_s, ruleName_s, action_s" -o table
