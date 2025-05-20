#! /bin/bash
# shellcheck disable=SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## This script deploys an AKS (Azure Kubernetes Service) cluster for a Korifi setup

##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/cf_utils.sh"
tmp="$scriptpath/tmp"
mkdir -p "$tmp"


##
## Config
##
export K8S_TYPE=AKS						# type: KIND, AKS
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. .env || { echo "Config ERROR! Script aborted"; exit 1;	# read config from environment file

# Script should be executed as root (just sudo fails for some commands)
strongly_advice_root


##
## Installing required tools
##

echo ""
echo ""
echo "---------------------------------------"
echo "Installing required tools"
echo "---------------------------------------"
echo ""

## GPG keys and repo sources are added in .env

install_if_missing apt jq jq "jq --version"
install_if_missing apt curl 
install_if_missing apt snap snapd
install_if_missing snap kubectl kubectl

# required for Azure CLI
install_if_missing apt package ca-certificates
install_if_missing apt package apt-transport-https
install_if_missing apt package lsb-release
install_if_missing apt package gnupg

install_go_if_missing "${GO_VERSION}"

##
## Install Azure CLI
##
function install_azure_cli() {

  echo "Install Azure CLI..."

  # Download and install the Microsoft signing key
  echo " - Download and install Microsoft signing key"
  curl -sL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | \
    $SUDOCMD tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null

  # Add the Azure CLI software repository
  echo " - Add Azure CLI software repo"
  AZ_REPO=$(lsb_release -cs)
  echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | \
    $SUDOCMD tee /etc/apt/sources.list.d/azure-cli.list

  install_if_missing apt az azure-cli "az version"

  echo "...done"
}

# TODO: Enable this command as soon as the AKS will be deployed in Azure in scope of this script
install_azure_cli





##
## Check Azure variables
##

prompt_if_missing AZ_SUBSCRIPTION_ID "var"    "Enter Azure Subscription ID"          "$AZ_ENV_FILE" validate_guid
prompt_if_missing AZ_APP_ID          "var"    "Enter Azure Service Principal App ID" "$AZ_ENV_FILE" validate_guid
prompt_if_missing AZ_CLIENT_SECRET   "secret" "Enter Azure Service Principal Secret" "$AZ_ENV_FILE" validate_not_empty
prompt_if_missing AZ_TENANT_ID       "var"    "Enter Azure Tenant ID"                "$AZ_ENV_FILE" validate_guid


## Azure Service Principal

# Define maximum retry attempts (optional)
MAX_ATTEMPTS=3
ATTEMPT=1

# Function to show instructions for creating the Service Principal (if needed)
show_instructions() {
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

# Keep trying to login, if not function (re-) enter credential os Azure Service Principal
until [ $ATTEMPT -gt $MAX_ATTEMPTS ]
do
  # Attempt login using Service Principal
  echo "Attempt to login: az login --service-principal -u \"$AZ_APP_ID\" -p \"*******************\" --tenant \"$AZ_TENANT_ID\""
  LOGIN_OUTPUT=$(az login --service-principal -u "$AZ_APP_ID" -p "$AZ_CLIENT_SECRET" --tenant "$AZ_TENANT_ID" 2>&1)
  LOGIN_SUCCESSFUL=$?

  echo "LOGIN_OUTPUT: $LOGIN_OUTPUT"
  echo "LOGIN_SUCCESSFUL: $LOGIN_SUCCESSFUL"

  # Check if the login was successful
  if [[ $LOGIN_SUCCESSFUL == 0 ]]; then
    echo "Service Principal login successful!"
    break  # Exit loop if login is successful
  fi

  echo "Login attempt $ATTEMPT failed! Details: $LOGIN_OUTPUT"

  # Show instructions for creating the Service Principal
  show_instructions

  # Ask the user to press Enter to retry or CTRL+C to abort
  echo "After creation provide the credentials of the Service Principal or press CTRL_C to abort"
  read -rp  "App-ID:        " AZ_APP_ID
  read -srp "Client Secret: " AZ_CLIENT_SECRET
  echo ""	# to force newline
  read -rp  "Tenant ID:     " AZ_TENANT_ID

  export AZ_APP_ID=$AZ_APP_ID
  export AZ_CLIENT_SECRET=$AZ_CLIENT_SECRET
  export AZ_TENANT_ID=$AZ_TENANT_ID

  # Increment the attempt counter
  ATTEMPT=$((ATTEMPT + 1))
done

# If login was not successful after max attempts, exit with error
if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
  echo "Failed to login after $MAX_ATTEMPTS attempts."
  exit 1
fi


echo ""
echo "Azure Data"
echo "=========="
echo "SubscriptionID: $AZ_SUBSCRIPTION_ID"
echo "Service Principal:"
echo "	App-ID:         $AZ_APP_ID"
echo "	Client Secret:  ${AZ_CLIENT_SECRET:0-4}..."
echo "	Tenant ID:      $AZ_TENANT_ID"
echo ""
echo "Now we can continue with the creation of the AKS cluster."
echo ""




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
  local aks_template="${scriptpath}/aks_deployment.json"
  local aks_parameters="${scriptpath}/aks_parameters.json"
  my_ip=$(curl ifconfig.me)
  aks_guid=$(uuidgen)

  echo "Deploy Azure Kubernetes Service Cluster '$aks_name' ($(date))"

  # Create the resource group
  echo "- create resource group '$resource_group'"
  #echo "  DBG: az group create --name \"$resource_group\" --location \"$location\""
  az group create --name "${resource_group}"    --location "$location"	# Cluster
  echo ""

  # Deploy the AKS cluster
  echo " - deploy Azure Kubernetes Service Cluster '$aks_name'"
  echo "   az deployment group create \\
    --resource-group \"$resource_group\" \\
    --template-file \"$aks_template\" \\
    --parameters @\"$aks_parameters\" \\
	resourceName=\"$aks_name\" \\
	subscriptionId=\"$AZ_SUBSCRIPTION_ID\" \\
	location=\"$location\" \\
	dnsPrefix=\"${aks_name}-dns\" \\
	kubernetesVersion=\"$K8S_VERSION\" \\
	nodeResourceGroup=\"${resource_group}_MC\" \\
	authorizedIPRanges=\"[\\\"${my_ip}\\\"]\" \\
	guidValue=\"$aks_guid\""

  az deployment group create \
    --resource-group "$resource_group" \
    --template-file "$aks_template" \
    --parameters @"$aks_parameters" \
  	 resourceName="$aks_name" \
  	 subscriptionId="$AZ_SUBSCRIPTION_ID" \
  	 location="$location" \
  	 dnsPrefix="${aks_name}-dns" \
  	 kubernetesVersion="$K8S_VERSION" \
  	 nodeResourceGroup="${resource_group}_MC" \
  	 authorizedIPRanges="[\"${my_ip}\"]" \
  	 guidValue="$aks_guid"
  result=$?
  if [[ "$result" -ne "0" ]]; then echo "Deployment of AKS cluster failed! Script aborted!"; exit 1; fi

  # Get credentials
  echo " - Get credentials"
  az aks get-credentials --resource-group "$resource_group" --name "$aks_name"

  # Wait for node readiness
  echo " - Waiting for node readiness"
  kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

# TODO: Enable once the AKS cluster will be deployed in Azure in scope of this script
install_azure_kubernetes_cluster "$K8S_CLUSTER_KORIFI"




echo ""
echo "------------------------------------------------------"
echo "Azure Kubernetes Service Cluster installation finished"
echo "------------------------------------------------------"
echo "Info:"
echo " - K8S Cluster:	$K8S_CLUSTER_KORIFI"
echo " - K8S Domain:	$(az aks list | jq -r ".[] | select(.name == \"$K8S_CLUSTER_KORIFI\") | .azurePortalFqdn")"
echo "------------------------------------------------------"
echo ""

