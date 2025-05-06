#! /bin/bash
# shellcheck disable=SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Installation of a basic Korifi Cluster on AKS (Azure Kubernetes Service)

##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"
tmp="$scriptpath/tmp"
mkdir -p "$tmp"



##
## Config
##

# Define Service Principal details
AZ_SERVICE_PRINCIPAL="SP_korifi"
AZ_APP_ID="your-application-id"
AZ_CLIENT_SECRET="your-client-secret"
AZ_TENANT_ID="your-tenant-id"

export K8S_CLUSTER_KORIFI=korifi
#? export k8s_cluster_korifi_yaml="${scriptpath}/k8s_korifi_cluster_config.yaml"
#? export GATEWAY_CLASS_NAME="contour"
export GO_VERSION=1.24.2
export GO_PACKAGE="go${GO_VERSION}.linux-amd64.tar.gz"
export K8S_VERSION="1.30.0"


strongly_advice_root

# Assert Config
#assert is_valid_guid "$AZ_SUBSCRIPTION_ID"


##
## Installing required tools
##

echo ""
echo ""
echo "Installing required tools"
echo "-------------------------"
echo ""

$SUDOCMD apt install -y jq curl							# general tools
$SUDOCMD apt install -y ca-certificates apt-transport-https lsb-release gnupg	# requirements for Azure

#verify required tools
assert jq --version
#? assert ca-certificates -??
#? assert apt-transport-https -??
#? assert lsb-release -??
#? assert gnupg -??


## Install yq (jq alike tool for yaml files)
echo "Installing yq..."
$SUDOCMD snap install yq
echo "verify result:"
assert yq --version
# expected: version of of yq
echo "...done"
echo ""


## Install Go
# based on: https://go.dev/doc/install
echo "Installing Go..."
wget https://go.dev/dl/${GO_PACKAGE} -O "$tmp/${GO_PACKAGE}"
tar -C /usr/local -xzf "$tmp/${GO_PACKAGE}"
export PATH=$PATH:/usr/local/go/bin                                     # add go/bin folder to PATH
echo "export PATH=$PATH:/usr/local/go/bin" >/etc/profile.d/go.sh        # and make it persistent
echo "verify result:"
assert "go version"
# expected: version info of go
echo "...done"
echo ""


## Install kubectl
echo "Install kubectl (if required)..."
$SUDOCMD snap install kubectl --classic
echo "verify result:"
assert which kubectl
# expected: /snap/bin/kubectl
echo "...done"
echo ""


## Install helm
echo "Install helm (if required)..."
curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/helm.gpg > /dev/null	# Add the Helm GPG key
$SUDOCMD apt install -y apt-transport-https										# install dependencies for helm
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list	# Add reqruied repo source for helm
$SUDOCMD apt update && $SUDOCMD apt install -y helm									# Update package list and Install Helm
#verify
echo "verify result:"
assert helm version
# expected: version.BuildInfo{Version:"v3.17.2", GitCommit:"cc0bbbd6d6276b83880042c1ecb34087e84d41eb", GitTreeState:"clean", GoVersion:"go1.23.7"}
echo "...done"
echo ""


## Install cf (cloudfoundry CLI)
# based on: https://docs.cloudfoundry.org/cf-cli/install-go-cli.html
echo "Install cf (cloud foundry command)..."
# add cloudfoundry foundation pyblic key and package repository to your system
curl -fsSL https://packages.cloudfoundry.org/debian/cli.cloudfoundry.org.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/cloudfoundry.org.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudfoundry.org.gpg] https://packages.cloudfoundry.org/debian stable main" | sudo tee /etc/apt/sources.list.d/cloudfoundry-cli.list
$SUDOCMD apt update && $SUDOCMD apt install -y cf8-cli	# Update package list and Install cf8-cli
# Note: above fails (for both version) on SynoNAS VM, below works fine, but fails on Azure VM
#	wget -O - https://packages.cloudfoundry.org/stable?release=debian64&version=v8&source=github cf8-cli.deb
#	sudo dpkg -i cf8-cli.deb
echo "verify:"
assert cf --version
#expected: help of cf command
echo "...done"


##
## Install Azure CLI
##
function install_azure_cli() {

  echo "Install Azure CLI..."

  # Download and install the Microsoft signing key
  echo " - Download and install Microsoft signing key"
  curl -sL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | \
    sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null

  # Add the Azure CLI software repository
  echo " - Add Azure CLI software repo"
  AZ_REPO=$(lsb_release -cs)
  echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | \
    sudo tee /etc/apt/sources.list.d/azure-cli.list

  # Update repository information and install the Azure CLI
  echo " - Update repository info and install Azure CLI"
  $SUDOCMD apt update
  $SUDOCMD apt install -y azure-cli

  # Verify
  echo " - verify"
  az version

  echo "...done"
}

# TODO: Enable this command as soon as the AKS will be deployed in Azure in scope of this script
install_azure_cli



##
## Check Azure credentials
##

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

# Start do until loop
until [ $ATTEMPT -gt $MAX_ATTEMPTS ]
do
  # Attempt login using Service Principal
  echo "Attempt to login: az login --service-principal -u \"$AZ_APP_ID\" -p \"********************************************************************************************************\" --tenant \"$AZ_TENANT_ID\""
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
  read -p  "App-ID:        " AZ_APP_ID
  read -sp "Client Secret: " AZ_CLIENT_SECRET
  echo ""	# to force newline
  read -p  "Tenant ID:     " AZ_TENANT_ID
  
  # Increment the attempt counter
  ATTEMPT=$((ATTEMPT + 1))
done

# If login was not successful after max attempts, exit with error
if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
  echo "Failed to login after $MAX_ATTEMPTS attempts."
  exit 1
fi


echo "Now we can continue with the creation of the AKS cluster."


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

  echo "Deploy Azure Kubernetes Service Cluster '$aks_name'"

  # Create the resource group
  echo "- create resource group '$resource_group'"
  echo "  DBG: az group create --name \"$resource_group\" --location \"$location\""
  az group create --name "$resource_group" --location "$location"
  echo ""

  # Deploy the AKS cluster
  echo " - deploy Azure Kubernetes Service Cluster '$aks_name'"
  echo "   az deployment group create \
    --resource-group \"$resource_group\" \
    --template-file \"$aks_template\" \
    --parameters @\"$aks_parameters\" \
                 resourceName=\"$aks_name\" \
                 location=\"$location\" \
                 dnsPrefix=\"${aks_name}-dns\" \
                 kubernetesVersion=\"$K8S_VERSION\" \
                 nodeResourceGroup=\"MC_${aks_name}_${aks_name}_${location}\" \
                 authorizedIPRanges=\"${my_ip}\" \
                 guidValue=\"$aks_guid\""

  az deployment group create \
    --resource-group "$resource_group" \
    --template-file "$aks_template" \
    --parameters @"$aks_parameters" \
                 resourceName="$aks_name" \
		 location="$location" \
		 dnsPrefix="${aks_name}-dns" \
		 kubernetesVersion="$K8S_VERSION" \
		 nodeResourceGroup="MC_${aks_name}_${aks_name}_${location}" \
		 authorizedIPRanges="[\"${my_ip}\"]" \
		 guidValue="$aks_guid"
  
  # Get credentials
  echo " - Get credentials"
  az aks get-credentials --resource-group "$resource_group" --name "$aks_name"
  
  # Wait for node readiness
  echo " - Waiting for node readiness"
  kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

# TODO: Enable once the AKS cluster will be deployed in Azure in scope of this script
install_azure_kubernetes_cluster "aks_test01"



echo  "REST OF SCRIPT NOT TESTED YET!!!"
exit 1

##
## Some patches / workarounds 
##

## Issue: 
## helm dependency build
## no repository definition for https://kubernetes-charts.storage.googleapis.com/
##
## Explanation:
## This URL is deprecated — it was the default Helm stable chart repo used in Helm v2, but it’s been shut down.
##
## Fix:
## Add the new location for the stable repo manually:
helm repo add stable https://charts.helm.sh/stable
helm repo update




##
## Install Korifi cluster
##

# based on: https://github.com/cloudfoundry/korifi/blob/main/INSTALL.kind.md
echo ""
echo ""
echo "Installing Korifi"
echo "-----------------"
echo ""
echo "to see logs, use: $SUDOCMD kubectl -n korifi-installer logs --follow job/install-korifi"

# run the installer job
echo " - run installer job"
$SUDOCMD kubectl apply -f https://github.com/cloudfoundry/korifi/releases/latest/download/install-korifi-kind.yaml

# Wait for the installer job to complete
echo -n "Waiting for installer job to complete."
while [ "$(kubectl get jobs -n korifi-installer 2>/dev/null | grep 'install-korifi' | awk '{print $3}')" != "1/1" ]; do
  sleep 1
  echo -n "."
done
echo "completed."

# Wait for all pods in the korifi namespace to be ready
$SUDOCMD kubectl wait --for=condition=Ready pods --all --namespace korifi --timeout=300s

# Verify
assert cf version

echo "Korifi installation complete."



##
## Login to Korifi as admin and show some demoe results
##

cf api https://localhost --skip-ssl-validation
cf login -u kind-korifi

# create a default org and default space
cf create-org org
cf create-space -o org space
cf target -o org -s space





## Create a Kubernetes service account
# TODO: Check whether this account is still required!
# PRE K8s v1.24:
#if [[ ! $(kubectl get sa korifi-user 2>/dev/null) ]];then
#  echo "Create korifi-user..."
#  kubectl create sa korifi-user -n default
#fi
#
#if [[ ! $(kubectl get clusterrolebinding korifi-user-bindingi 2>/dev/null) ]];then
#  echo "Creating clusterrolebinding for korifi-user..."
#  kubectl create clusterrolebinding korifi-user-binding \
#    --clusterrole=cluster-admin \
#    --serviceaccount=default:korifi-user
#fi
#
#kubectl apply -f - <<EOF
#apiVersion: v1
#kind: Secret
#metadata:
#  name: korifi-user-token
#  annotations:
#    kubernetes.io/service-account.name: korifi-user
#type: kubernetes.io/service-account-token
#EOF





#
# End message
#
echo ""
echo "======== Korifi install finished ========"
echo ""
echo ""

