
echo -e "${HIGHLIGHT} Deploy and configure demos for $1 with subdomains $2 $3 $4"

# Create Azure Storage Account
STORAGE_AVAILABLE=$(az storage account check-name --name $STORAGE_ACCOUNT_NAME --query "reason")

if [[ ! ($STORAGE_AVAILABLE -eq "AlreadyExists") ]]
then
    echo -e "${HIGHLIGHT} Creating storage account ${STORAGE_ACCOUNT_NAME}...${VERBOSE_COLOR}"
    az storage account create \
    --name $STORAGE_ACCOUNT_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION

    # Enable static website
    az storage blob service-properties update \
    --account-name $STORAGE_ACCOUNT_NAME \
    --static-website

    # Get static website url for heroes images
    STATIC_WEB_SITE_URL=$(az storage account show \
    --name $STORAGE_ACCOUNT_NAME \
    --resource-group $RESOURCE_GROUP \
    --query primaryEndpoints.web \
    --output tsv)

    echo -e "${HIGHLIGHT}Upload images ${VERBOSE_COLOR}"
    az storage blob upload-batch \
    --account-name $STORAGE_ACCOUNT_NAME \
    --destination \$web \
    --source images

else
    echo -e "${HIGHLIGHT} Deploy demos...${VERBOSE_COLOR}"

    NAMESPACE_NAME=$(echo $1 | sed 's/\./-/g')

    for i in "${@:2}"
    do
        # Get random file in images
        IMAGE_NAME=$(ls images | sort -R | awk 'NR==2')

        # brew install gettext
        # brew link --force gettext        
        NAMESPACE_NAME=$NAMESPACE_NAME DOMAIN=$1 SUBDOMAIN=$i STATIC_WEB_SITE_URL=$STATIC_WEB_SITE_URL IMAGE_NAME=$IMAGE_NAME \
         envsubst < demos/ingress-demo.yaml | kubectl apply -f -
    done 
fi

kubectl get all -n $NAMESPACE_NAME
kubectl get ingress -n $NAMESPACE_NAME