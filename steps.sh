## 00 - Set variables
source 00-variables.sh

## 01 - Create AKS cluster
source 01-create-aks-cluster.sh

## 02 - Install traefik
source 02-install-traefik.sh

## (optional) 03 - Test private link from a VM
# source 02.1-test-private-link-from-a-vm.sh

## 04 - Create Azure Front Door Profile with Traefik PLS as origin
source 04-create-azure-front-door-profile.sh

## 05 - Add custom domains to the endpoint
# Parameters: domain subdomain
source 05-add-custom-domains.sh azuredemo.es www
source 05-add-custom-domains.sh matrixapp.es www
source 05-add-custom-domains.sh domaingis.com www

source 05-add-custom-domains.sh azuredemo.es api
source 05-add-custom-domains.sh matrixapp.es api
source 05-add-custom-domains.sh domaingis.com api

source 05-add-custom-domains.sh azuredemo.es dev
source 05-add-custom-domains.sh matrixapp.es dev
source 05-add-custom-domains.sh domaingis.com dev

## 06 - Assign WAF Policies to the subdomains
# Parameters: subdomain waf_mode
source 06-add-waf-policies.sh www Prevention
source 06-add-waf-policies.sh api Prevention
source 06-add-waf-policies.sh dev Detection

## 07 - Add diagnostics
source 07-add-diagnostics.sh

## 08 - Test Ingress Controller
source 08-test-ingress-controller.sh azuredemo.es www api dev
source 08-test-ingress-controller.sh matrixapp.es www api dev
source 08-test-ingress-controller.sh domaingis.com www api dev

## 09 - Test WAF
source 09-test-waf.sh www.azuredemo.es
source 09-test-waf.sh api.matrixapp.es
source 09-test-waf.sh dev.domaingis.com

# Check traefik dashboard
kubectl port-forward $(kubectl get pods -l app=traefik -o jsonpath="{.items[].metadata.name}") 8080:8080

## 10 - Clean all
source 10-clean-all.sh

## 11 - Clean GoDaddy records
source 11-clean-goddady-records.sh azuredemo.es www api dev
source 11-clean-goddady-records.sh matrixapp.es www api dev
source 11-clean-goddady-records.sh domaingis.com www api dev


### Limits ###
# https://learn.microsoft.com/en-us/azure/frontdoor/front-door-routing-limits
# https://github.com/MicrosoftDocs/azure-docs/blob/main/includes/front-door-limits.md#azure-front-door-standard-and-premium-tier-service-limits