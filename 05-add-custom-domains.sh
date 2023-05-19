echo -e "${HIGHLIGHT}Domain: $1 Subdomain: $2${VERBOSE_COLOR}"

SUBDOMAIN=$2

CUSTOM_DOMAIN_NAME=$1
CUSTOM_DOMAIN_WITH_DASHES=$(echo "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME" | sed 's/\./-/g')

# Create a custom domain
echo -e "${HIGHLIGHT} Creating custom domain $CUSTOM_DOMAIN_NAME...${VERBOSE_COLOR}"
az afd custom-domain create \
--resource-group $RESOURCE_GROUP \
--custom-domain-name $CUSTOM_DOMAIN_WITH_DASHES \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--host-name "$SUBDOMAIN.$CUSTOM_DOMAIN_NAME" \
--minimum-tls-version TLS12 \
--certificate-type ManagedCertificate

# Get the TXT value to add to the DNS record
TXT_VALIDATION_TOKEN=$(az afd custom-domain show --resource-group $RESOURCE_GROUP --profile-name $AZURE_FRONT_DOOR_PROFILE_NAME --custom-domain-name $CUSTOM_DOMAIN_WITH_DASHES --query "validationProperties.validationToken" -o tsv)

# You should add a TXT record to the DNS zone of the custom domain
echo "Record type: TXT"
echo "Record name: _dnsauth.$SUBDOMAIN"
echo "Record value: $TXT_VALIDATION_TOKEN"

echo -e "${HIGHLIGHT}Call GoDaddy to register TXT record${VERBOSE_COLOR}"

source 5.1-configure-goddady.sh $CUSTOM_DOMAIN_NAME TXT _dnsauth.$SUBDOMAIN $TXT_VALIDATION_TOKEN

# Verify the custom domain
az afd custom-domain wait \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--custom-domain-name $CUSTOM_DOMAIN_WITH_DASHES \
--custom "domainValidationState!='Pending'" \
--interval 30 --debug \
--timeout 60

# Get TXT record from a domain
dig TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME
nslookup -type=TXT _dnsauth.$SUBDOMAIN.$CUSTOM_DOMAIN_NAME

# You should add a CNAME record to the DNS zone of the custom domain
echo "Record type: CNAME"
echo "Record name: $SUBDOMAIN"
echo "Record value: $AFD_HOST_NAME."

echo -e "${HIGHLIGHT}Call GoDaddy to register the CNAME record${VERBOSE_COLOR}"

source 5.1-configure-goddady.sh $DOMAIN_NAME CNAME $SUBDOMAIN $AFD_HOST_NAME.

echo -e "${HIGHLIGHT}Get all custom domains associated to the endpoint${VERBOSE_COLOR}"
CUSTOM_DOMAINS_ID=$(az afd route show \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME \
--query "customDomains[].id" -o tsv)

CUSTOM_DOMAINS_NAMES=$(az afd custom-domain show \
--ids $CUSTOM_DOMAINS_ID \
--query "name" -o tsv | tr '\n' ' ')

if [[ $CUSTOM_DOMAINS_NAMES == '' ]]
then
    CUSTOM_DOMAINS_NAMES=$(az afd custom-domain show \
    --ids $CUSTOM_DOMAINS_ID \
    --query "[].name" -o tsv | tr '\n' ' ')
fi

echo -e "${HIGHLIGHT}Add the custom domain ${CUSTOM_DOMAIN_NAME} to the route${VERBOSE_COLOR}"
az afd route update \
--resource-group $RESOURCE_GROUP \
--profile-name $AZURE_FRONT_DOOR_PROFILE_NAME \
--endpoint-name $ENDPOINT_NAME \
--route-name $AFD_ROUTE_NAME \
--custom-domains $(echo $CUSTOM_DOMAINS_NAMES) $CUSTOM_DOMAIN_WITH_DASHES
