echo "Domain name: $1  Record: $2 Record name: $3 Value: $4"

DOMAIN_NAME=$1
RECORD_TYPE=$2
RECORD_NAME=$3
RECORD_VALUE=$4

echo -e "${HIGHLIGHT} Calling GoDaddy to add $RECORD_NAME with value $RECORD_VALUE for $DOMAIN_NAME${VERBOSE_COLOR}"

# Set TXT record
curl -X PUT -H "Authorization: sso-key $GODADDY_KEY:$GODADDY_SECRET" \
"$GODADDY_ENDPOINT/v1/domains/$DOMAIN_NAME/records/$RECORD_TYPE/$RECORD_NAME" \
--data "[{\"data\": \"$RECORD_VALUE\",\"ttl\": 600}]" -H "Content-Type: application/json"

echo -e "${HIGHLIGHT} Done 👍"
