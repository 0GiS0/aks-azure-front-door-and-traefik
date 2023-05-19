# Variables
RESOURCE_GROUP="afd-and-aks-with-traefik-poc"
LOCATION="westeurope"
AKS_CLUSTER_NAME="aks-cluster"
AKS_VNET="aks-vnet"
AKS_SUBNET="aks-subnet"
PLS_SUBNET="pls-subnet"
# Azure Front Door variables
AZURE_FRONT_DOOR_PROFILE_NAME="${RESOURCE_GROUP}"
ENDPOINT_NAME="traefik-endpoint"
AFD_ORIGIN_GROUP_NAME="aks-origin-group"
AFD_ROUTE_NAME="traefik-route"
STORAGE_ACCOUNT_NAME="herostore${RANDOM}"
# Colors for the shell
HIGHLIGHT='\033[1;34m' 
VERBOSE_COLOR='\033[0;32m'

# GoDaddy variables
GODADDY_KEY="<YOUR_PRODUCTION_GODADDY_KEY>"
GODADDY_SECRET="<YOUR_PRODUCTION_GODADDY_SECRET>"
GODADDY_ENDPOINT="https://api.godaddy.com"

echo -e "${HIGHLIGHT}Variables set! 🫡"