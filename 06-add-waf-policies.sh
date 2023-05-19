# A security policy includes a web application firewall (WAF) policy and one or more domains to provide centralized protection for your web applications.
# https://docs.microsoft.com/en-us/azure/frontdoor/front-door-security-policies

SUBDOMAIN=$1
WAF_POLICY_NAME=$1
MODE=$2
ACTION=Block

if [[ $MODE == 'Detection' ]]; then ACTION=Log; fi

# Create a Azure Front Door policy
echo -e "${HIGHLIGHT}Creating a WAF policy 🧱 for ${SUBDOMAIN} subdomains${VERBOSE_COLOR}"
az network front-door waf-policy create \
--resource-group $RESOURCE_GROUP \
--name $WAF_POLICY_NAME \
--mode $MODE \
--sku Premium_AzureFrontDoor

# Add a managed rule to the WAF policy
echo -e "${HIGHLIGHT}Add managed rules 📐${VERBOSE_COLOR}"
az network front-door waf-policy managed-rules add \
--resource-group $RESOURCE_GROUP \
--policy-name $WAF_POLICY_NAME \
--type Microsoft_DefaultRuleSet \
--version 2.1 \
--action $ACTION

# Add bot rules
echo -e "${HIGHLIGHT}Add bot rules 🤖${VERBOSE_COLOR}"
az network front-door waf-policy managed-rules add \
--resource-group $RESOURCE_GROUP \
--policy-name $DEV_WAF_POLICY_NAME \
--type Microsoft_BotManagerRuleSet \
--version 1.0 \
--action $ACTION

# Create custom rule
echo -e "${HIGHLIGHT}Add a custom rule 📏${VERBOSE_COLOR}"
az network front-door waf-policy rule create \
--resource-group $RESOURCE_GROUP \
--policy-name $WAF_POLICY_NAME \
--name "${SUBDOMAIN}customrule" \
--priority 1 \
--rule-type MatchRule \
--action $ACTION \
--defer

# Add a condition to the custom rule
az network front-door waf-policy rule match-condition add \
--match-variable QueryString \
--operator Contains \
--values "blockme" \
--name "${SUBDOMAIN}customrule" \
--resource-group $RESOURCE_GROUP \
--policy-name $WAF_POLICY_NAME

# Check custom rules
az network front-door waf-policy rule list \
--resource-group $RESOURCE_GROUP \
--policy-name $WAF_POLICY_NAME

# Custom error page
echo -e "${HIGHLIGHT} You can also use a custom page for 403 errors 💀${VERBOSE_COLOR}"
az network front-door waf-policy update \
--resource-group $RESOURCE_GROUP \
--name $WAF_POLICY_NAME \
--custom-block-response-body $(cat custom-error/403.html | base64)

# Get the WAF policy ID
WAF_POLICY_ID=$(az network front-door waf-policy show \
--resource-group $RESOURCE_GROUP \
--name $WAF_POLICY_NAME --query "id" -o tsv)

# Get custom domains
echo -e "${HIGHLIGHT} Associate custom domains that contains ${SUBDOMAIN} in their name to the security group${VERBOSE_COLOR}"
CUSTOM_DOMAINS_ID=$(az afd custom-domain list \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--query "[?contains(hostName,'${SUBDOMAIN}')].id" -o tsv)

# Glue the WAF policy to the security policy
az afd security-policy create \
--security-policy-name $SUBDOMAIN \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--waf-policy $WAF_POLICY_ID \
--domains $(echo $CUSTOM_DOMAINS_ID | tr '\n' ' ')

echo -e "${HIGHLIGHT} Security policy '${SUBDOMAIN}' created 🤓"
