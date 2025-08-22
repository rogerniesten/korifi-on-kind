#! /bin/bash
# shellcheck disable=SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## This script deploys an AKS (Azure Kubernetes Service) cluster for a Korifi setup

##

## Includes
. env/.env || { echo "Config ERROR! Script aborted"; exit 1; }  	# read paths from environment file
. "$LIB_PATH/cf_utils.sh"


##
## Config
##

# logging
export log_level="$LOG_TRC"
export show_timestamp=false
export log_commands_always=true

# korifi
K8S_TYPE=AKS								# type: KIND, AKS
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. "$ENV_PATH/.env_korifi" || die 1 "Config ERROR! Script aborted"	# read korifi config from environment file

# Script should be executed as root (just sudo fails for some commands)
strongly_advice_root


##
## Installing required tools
##

log "$LOG_INF" "
---------------------------------------
Installing required tools
---------------------------------------
"

## GPG keys and repo sources are added in .env

install_if_missing apt jq jq "jq --version"
install_if_missing apt curl 
install_if_missing apt snap snapd
install_if_missing snap go go "go version"
install_if_missing snap kubectl kubectl

# required for Azure CLI
install_if_missing apt package ca-certificates
install_if_missing apt package apt-transport-https
install_if_missing apt package lsb-release
install_if_missing apt package gnupg


##
## Install Azure CLI
##
function install_azure_cli() {

  log "$LOG_DBG" "Install Azure CLI..."

  # Download and install the Microsoft signing key
  if [[ ! -f /etc/apt/trusted.gpg.d/microsoft.gpg ]]; then
    log "$LOG_DBG" "Prepare AzureCLI installation (Download and install Microsoft signing key)"
    curl -sL https://packages.microsoft.com/keys/microsoft.asc | \
      gpg --dearmor | \
      $SUDOCMD tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
  fi

  # Add the Azure CLI software repository
  AZ_REPO=$(lsb_release -cs)
  if ! grep "$AZ_REPO main" /etc/apt/sources.list.d/azure-cli.list >/dev/null; then
    log "$LOG_DBG" "Prepare AzureCLI installation (Add Azure CLI software repo)"
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | \
      $SUDOCMD tee /etc/apt/sources.list.d/azure-cli.list
  fi

  install_if_missing apt az azure-cli "az version"
}

# TODO: Enable this command as soon as the AKS will be deployed in Azure in scope of this script
install_azure_cli





##
## Check Azure credentials and variables
##

# Function to show instructions for creating the Service Principal (if needed)
function show_instructions() {
  echo ""
  echo "It seems the Service Principal login failed. Please ensure that the Service Principal exists."
  echo "You can create a Service Principal in Azure CLI or via the Azure Portal."
  echo ""
  echo "To create a Service Principal to create the AKS using Azure CLI, run the following commands:"
  echo ""
  echo "az ad sp create-for-rbac --name \"$AZ_SERVICE_PRINCIPAL\" --role Contributor --scopes /subscriptions/\$(az account show --query id --output tsv)"
  echo ""
  echo "Alternatively, you can create the Service Principal via the Azure Portal by navigating to Azure Active Directory -> App registrations -> New registration."
  echo ""
  echo "Once the Service Principal is created, retry this script by pressing Enter."
  echo "You can also press CTRL+C to abort the script."
  echo ""
}


function login_to_azure() {
   prompt_if_missing AZ_SUBSCRIPTION_ID "var"    "Enter Azure Subscription ID"          "$AZ_ENV_FILE" validate_guid
   prompt_if_missing AZ_APP_ID          "var"    "Enter Azure Service Principal App ID" "$AZ_ENV_FILE" validate_guid
   prompt_if_missing AZ_CLIENT_SECRET   "secret" "Enter Azure Service Principal Secret" "$AZ_ENV_FILE" validate_not_empty
   prompt_if_missing AZ_TENANT_ID       "var"    "Enter Azure Tenant ID"                "$AZ_ENV_FILE" validate_guid

   # Define maximum retry attempts (optional)
   MAX_ATTEMPTS=3
   ATTEMPT=1

   # Keep trying to login, if not function (re-) enter credential os Azure Service Principal
   until [ $ATTEMPT -gt $MAX_ATTEMPTS ]
   do
    # Attempt login using Service Principal
    log "$LOG_DBG" "Attempt to login to azure"
    log "$LOG_CMD" "az login --service-principal -u \"$AZ_APP_ID\" -p \"${AZ_CLIENT_SECRET:0:4}*******************\" --tenant \"$AZ_TENANT_ID\""
    if az login --service-principal -u "$AZ_APP_ID" -p "$AZ_CLIENT_SECRET" --tenant "$AZ_TENANT_ID" 2>&1; then
      log "$LOG_TRC" "Service Principal login successful!"
      break  # Exit loop if login is successful
    fi

    log "$LOG_WRN" "Login attempt $ATTEMPT failed! Details: $LOGIN_OUTPUT"
    show_instructions

    # Ask the user to press Enter to retry or CTRL+C to abort
    echo "After creation, provide the credentials of the Service Principal or press CTRL_C to abort"
    read -rp  "App-ID:        " AZ_APP_ID
    read -srp "Client Secret: " AZ_CLIENT_SECRET
    echo ""     # to force newline
    read -rp  "Tenant ID:     " AZ_TENANT_ID

    export AZ_APP_ID=$AZ_APP_ID
    export AZ_CLIENT_SECRET=$AZ_CLIENT_SECRET
    export AZ_TENANT_ID=$AZ_TENANT_ID

    # Increment the attempt counter
    ATTEMPT=$((ATTEMPT + 1))
  done

  # If login was not successful after max attempts, exit with error
  if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    die 1 "Failed to login after $MAX_ATTEMPTS attempts."
  fi
}


if az account show > /dev/null 2>&1 ; then
  log "$LOG_DBG" "Already logged in to Azure, so no need to login explicitly."
else
  log "$LOG_WRN" "Not logged in to Azure yet, let's login now."
  login_to_azure
fi


log "$LOG_DBG" "
Azure Data
==========
SubscriptionID:	$AZ_SUBSCRIPTION_ID
Service Principal:
- App-ID:         $AZ_APP_ID
- Client Secret:  ${AZ_CLIENT_SECRET:0-4}...
- Tenant ID:      $AZ_TENANT_ID
"
log "$LOG_INF" "Now we can continue with the creation of the AKS cluster.\n"


##
## Deploy the AKS cluster
##
function install_azure_kubernetes_cluster() {
  local aks_name="$1"
  local resource_group="${2:-$aks_name}"
  local location="westeurope"

  # validate requirements
  assert az version

  # local vars
  local my_ip aks_guid
  local aks_template="${CFG_PATH}/aks_deployment.json"
  local aks_parameters="${CFG_PATH}/aks_parameters.json"
  my_ip=$(curl -s ifconfig.me)
  aks_guid=$(uuidgen)

  log "$LOG_INF" "Deploy Azure Kubernetes Service Cluster '$aks_name' ($(date))"

  # Create the resource group
  log "$LOG_DBG" "- create resource group '$resource_group'"
  #echo "  DBG: az group create --name \"$resource_group\" --location \"$location\""
  az group create --name "${resource_group}"    --location "$location"	# Cluster
  

  # Deploy the AKS cluster
  log "$LOG_DBG" " - deploy Azure Kubernetes Service Cluster '$aks_name'"
  log "$LOG_CMD" "   az deployment group create \\
    --resource-group \"$resource_group\" \\
    --template-file \"$aks_template\" \\
    --parameters @\"$aks_parameters\" \\
	resourceName=\"$aks_name\" \\
	subscriptionId=\"$AZ_SUBSCRIPTION_ID\" \\
	location=\"$location\" \\
	dnsPrefix=\"${aks_name}-dns\" \\
	kubernetesVersion=\"$K8S_VERSION\" \\
	nodeResourceGroup=\"${resource_group}_mc\" \\
	authorizedIPRanges=\"[\\\"${my_ip}\\\"]\" \\
	guidValue=\"$aks_guid\""

  if ! az deployment group create \
          --resource-group "$resource_group" \
          --template-file "$aks_template" \
          --parameters @"$aks_parameters" \
    	    resourceName="$aks_name" \
  	    subscriptionId="$AZ_SUBSCRIPTION_ID" \
  	    location="$location" \
  	    dnsPrefix="${aks_name}-dns" \
  	    kubernetesVersion="$K8S_VERSION" \
  	    nodeResourceGroup="${resource_group}_mc" \
  	    authorizedIPRanges="[\"${my_ip}\"]" \
  	    guidValue="$aks_guid"; then
    die 1 "Deployment of AKS cluster failed! Script aborted!"
  fi

  # Get credentials
  log "$LOG_DBG" " - Get credentials"
  az aks get-credentials --resource-group "$resource_group" --name "$aks_name" --overwrite-existing

  # Wait for node readiness
  log "$LOG_DBG" " - Waiting for node readiness"
  kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

# TODO: Enable once the AKS cluster will be deployed in Azure in scope of this script
install_azure_kubernetes_cluster "$K8S_CLUSTER_KORIFI"



function create_nsg_outbound_rule() {
  local node_resource_group="$1"
  local nsg_name="$2"
  local priority="$3"
  local access="$4"
  local name="$5"
  local desc="${6:-}"
  local dst_prefix="${7:-'*'}"
  local dst_ports="${8:-'*'}"
  local protocol="${9:-*}"
  local src_prefix="${10-VirtualNetwork}"

  log "$LOG_CMD" "az network nsg rule create \\
    --resource-group $node_resource_group \\
    --nsg-name $nsg_name \\
    --name $name \\
    --priority $priority \\
    --direction Outbound \\
    --access $access \\
    --protocol $protocol \\
    --source-address-prefixes $src_prefix \\
    --destination-address-prefixes $dst_prefix \\
    --destination-port-ranges $dst_ports \\
    --description \"${desc}\""

    az network nsg rule create \
    --resource-group "$node_resource_group" \
    --nsg-name "$nsg_name" \
    --name "$name" \
    --priority "$priority" \
    --direction Outbound \
    --access "$access" \
    --protocol "$protocol" \
    --source-address-prefixes "$src_prefix" \
    --destination-address-prefixes "$dst_prefix" \
    --destination-port-ranges "$dst_ports" \
    --description "${desc}"
}


function configure_networking() {
  local node_resource_group="${K8S_CLUSTER_KORIFI}_mc"
  local vnet_name nsg_id nsg_name registry_ip aks_controlplane_domain aks_ctrlplane_ip
  log "$LOG_DBG" "retrieving name of Network Security Group"
  log "$LOG_CMD" "vnet_name=\$(az network vnet list --resource-group $node_resource_group --query '[0].name' --output tsv)"
  vnet_name=$(az network vnet list --resource-group "$node_resource_group" --query '[0].name' --output tsv)
  log "$LOG_CMD" "nsg_id=\$(az network vnet subnet list --resource-group $node_resource_group --vnet-name $vnet_name --query '[0].networkSecurityGroup.id' --output tsv)"
  nsg_id=$(az network vnet subnet list --resource-group "$node_resource_group" --vnet-name "$vnet_name" --query '[0].networkSecurityGroup.id' --output tsv)
  log "$LOG_CMD" "nsg_name=\$(az network nsg list --resource-group $node_resource_group --query \"[?id=='$nsg_id']\".name --output tsv)"
  nsg_name=$(az network nsg list --resource-group "$node_resource_group" --query "[?id=='$nsg_id']".name --output tsv)

  log "$LOG_DBG" "get image registry IP"
  log "$LOG_CMD" "registry_ip=\$(dig +short $LOCAL_IMAGE_REGISTRY_FQDN)"
  registry_ip=$(dig +short "$LOCAL_IMAGE_REGISTRY_FQDN")
  
  log "$LOG_DBG" "get controlplan IP"
  log "$LOG_CMD" "aks_controlplane_domain=\$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's|https?://([^:/]+).*|\1|')"
  aks_controlplane_domain=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's|https?://([^:/]+).*|\1|')
  log "$LOG_CMD" "aks_controlplane_ip=\$(echo \"$aks_controlplane_domain\" | sed -E 's|https?://([^:/]+).*|\1|' | xargs dig +short)"
  aks_ctrlplane_ip=$(echo "$aks_controlplane_domain" | sed -E 's|https?://([^:/]+).*|\1|' | xargs dig +short)

  log "$LOG_DBG" "Create network firewall rules"
  create_nsg_outbound_rule "$node_resource_group" "$nsg_name" 140 Allow Allow-ControlPlane "Allow AKS node to access Controlplane"   "$aks_ctrlplane_ip" "443"
  create_nsg_outbound_rule "$node_resource_group" "$nsg_name" 150 Allow Allow-K8s-API      "Allow AKS node to access K8s API server" "10.0.0.1"          "443"
  create_nsg_outbound_rule "$node_resource_group" "$nsg_name" 200 Allow Allow-Registry     "Allow local container registry"          "$registry_ip"      "443 5000"
  create_nsg_outbound_rule "$node_resource_group" "$nsg_name" 400 Deny  Deny-Internet      "Block all outbound internet access"

  log "$LOG_DBG" "Overview firewall rules"
  log "$LOG_CMD" "az network nsg rule list --resource-group $node_resource_group --nsg-name $nsg_name --include-default --output table"
  az network nsg rule list --resource-group "$node_resource_group" --nsg-name "$nsg_name" --include-default --output table

}


## NOTE: Original goal was to ensure no external images were pulled
# Unfortunately this doesn't work reliably and therefore this has been commented out
# The code (see functions above) have ben preserved for future reference.
# TODO: Investigate further to get it working reliably!
#configure_networking




log "$LOG_INF" "creating baseline files for AKS Roles"
kubectl get clusterrole -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > "${tmp:-.}/default-clusterroles.txt"
kubectl get clusterrolebinding -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > "${tmp:-.}/default-clusterrolebindings.txt"




log "$LOG_INF" "
------------------------------------------------------
Azure Kubernetes Service Cluster installation finished
------------------------------------------------------
Info:
 - K8S Cluster:	$K8S_CLUSTER_KORIFI
 - K8S Domain:	$(az aks list | jq -r ".[] | select(.name == \"$K8S_CLUSTER_KORIFI\") | .azurePortalFqdn")
------------------------------------------------------
"

