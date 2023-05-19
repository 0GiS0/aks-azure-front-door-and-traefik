echo "${HIGHLIGHT}Cleaning domain name: $1"

DOMAIN_NAME=$1

for i in "${@:2}"
    do
        echo -e "${HIGHLIGHT}Cleaning TXT for $i ${VERBOSE_COLOR}"
        curl -X DELETE -H "Authorization: sso-key $GODADDY_KEY:$GODADDY_SECRET" \
        "$GODADDY_ENDPOINT/v1/domains/$DOMAIN_NAME/records/TXT/_dnsauth.$i"

        echo -e "${HIGHLIGHT}Cleaning CNAME for $i ${VERBOSE_COLOR}"
        curl -X DELETE -H "Authorization: sso-key $GODADDY_KEY:$GODADDY_SECRET" \
        "$GODADDY_ENDPOINT/v1/domains/$DOMAIN_NAME/records/CNAME/$i"

    done

echo -e "${HIGHLIGHT} Done 👍"