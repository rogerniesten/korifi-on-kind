#! /bin/bash
# shellcheck disable=SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Installation of a basic Korifi Cluster on AKS (Azure Kubernetes Service)

##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/cf_utils.sh"
tmp="$scriptpath/tmp"
mkdir -p "$tmp"


##
## Config
##
export K8S_TYPE=AKS	# type: KIND, AKS
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. .env || { echo "Config ERROR! Script aborted"; exit 1; }      # read config from environment file

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
install_if_missing apt helm helm "helm version"
install_if_missing apt cf cf8-cli

install_if_missing apt snap snapd
install_if_missing snap yq yq "yq --version"
install_if_missing snap kubectl snap #TODO: requires param --classic !!

# required for Azure CLI
install_if_missing apt package ca-certificates
install_if_missing apt package apt-transport-https
install_if_missing apt package lsb-release
install_if_missing apt package gnupg


## Install Go
# based on: https://go.dev/doc/install
if go version >/dev/null; then
  echo "✅ go (golang) is already installed."
else
  echo "Installing Go..."
  wget "https://go.dev/dl/${GO_PACKAGE}" -O "$tmp/${GO_PACKAGE}"
  tar -C /usr/local -xzf "$tmp/${GO_PACKAGE}"
  export PATH=$PATH:/usr/local/go/bin                                     # add go/bin folder to PATH
  echo "export PATH=$PATH:/usr/local/go/bin" >/etc/profile.d/go.sh        # and make it persistent
  echo "verify result:"
  assert "go version"
  # expected: version info of go
  echo "...done"
  echo ""
fi


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



# TODO: Split script in creation of Kubernetes Cluster and creation of Korifi cluster (indipendend from K8s cluster)



##
## Install Korifi cluster
##




# based on: https://github.com/cloudfoundry/korifi/blob/main/INSTALL.md

#
# First install the prerequisits
#
echo ""
echo ""
echo "---------------------------------------"
echo "Installing prerequisits for Korifi"
echo "---------------------------------------"
echo ""

## Install Cert Manager
echo "Installing cert-manager..."
echo "TRC: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml"
# Wait until all cert-manager pods are ready
echo "Waiting for cert-manager pods to become ready..."
while true; do
  # shellcheck disable=SC2126	# grep -c not possible here as param -v is not combineable with -c
  NOT_READY=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -v 'Running' | grep -v 'Completed' | wc -l)
  TOTAL=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | wc -l)
  if [[ "$TOTAL" -gt 0 && "$NOT_READY" -eq 0 ]]; then
    echo "✅ All cert-manager pods are ready."
    break
  fi
  echo "⏳ Still waiting... ($((TOTAL - NOT_READY))/$TOTAL ready)"
  sleep 3
done
echo "...done"
echo ""

## Install kpack
echo "Installing kpack..."
KPACK_RELEASE_FILE="${scriptpath}/tmp/release-${KPACK_VERSION}.yaml"
KPACK_RELEASE_URL="https://github.com/buildpacks-community/kpack/releases/download/v${KPACK_VERSION}/release-${KPACK_VERSION}.yaml"
# Step 0: Download the YAML
echo "TRC: curl -L \"$KPACK_RELEASE_URL\" -o \"${KPACK_RELEASE_FILE}\""
curl -Ls "$KPACK_RELEASE_URL" -o "${KPACK_RELEASE_FILE}"
# Step 1: Apply only CRDs (initial apply to install CRDs)
echo "TRC: kubectl apply --filename <(cat \"$KPACK_RELEASE_FILE\" | yq e 'select(.kind == \"CustomResourceDefinition\")')"
# shellcheck disable=SC2002	# due to permissions cat is required
kubectl apply --filename <(cat "$KPACK_RELEASE_FILE" | yq e 'select(.kind == "CustomResourceDefinition")')
# Step 2: Wait for ClusterLifecycle CRD to become available
echo "Waiting for ClusterLifecycle CRD to be registered..."
until kubectl get crd clusterlifecycles.kpack.io >/dev/null 2>&1; do
  echo -n "."
  sleep 2
done
echo "ClusterLifecycle CRD is now available."
# Step 3: Apply the release again to ensure all resources are created
echo "TRC: kubectl apply --filename \"$KPACK_RELEASE_FILE\""
kubectl apply --filename "$KPACK_RELEASE_FILE"
# Step 4: Verify kpack
#echo "Verify:"
# TODO: How?
echo "...done"
echo ""

## Install Contour Gateway
echo "Installing contour gateway..."
echo "- Contour Gateway Provisioner"
echo "TRC: kubectl apply -f https://raw.githubusercontent.com/projectcontour/contour/release-${CONTOUR_VERSION}/examples/render/contour-gateway-provisioner.yaml"
kubectl apply -f "https://raw.githubusercontent.com/projectcontour/contour/release-${CONTOUR_VERSION}/examples/render/contour-gateway-provisioner.yaml"
echo "- Contour Gateway Class"
echo "TRC: kubectl apply -f - <<EOF
kind: GatewayClass
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: $GATEWAY_CLASS_NAME
spec:
  controllerName: projectcontour.io/gateway-controller
EOF"
kubectl apply -f - <<EOF
kind: GatewayClass
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: $GATEWAY_CLASS_NAME
spec:
  controllerName: projectcontour.io/gateway-controller
EOF
#echo "Verify:"
# TODO: How?
echo "...done"
echo ""

## Install Metrics Server
kubectl get pods -A | grep metrics-server 1>/dev/null
metrics_server_installed=$?
if [[ $metrics_server_installed -eq 0 ]]; then
  # Metrics server is already installed implicitly on AKS
  echo "Metrics Server already installed, no action required"
else
  echo "Installing Metrics Server..."
  echo "TRC: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # verify
  echo "Verify:"
  # TODO: How?
  echo "...done"
fi




echo ""
echo ""
echo "---------------------------------------"
echo "Pre-install configuration"
echo "---------------------------------------"
echo ""

# Namespace creation (TODO: namespaces seem already to be existing, so these command seem to be superfluous and can be removed)
echo "Namespace creation"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ROOT_NAMESPACE
  labels:
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/enforce: restricted
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $KORIFI_NAMESPACE
  labels:
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/enforce: restricted
EOF
echo ""


# Container registry credentials Secret
echo "Container registry credentials Secret"
# dummies are sufficient for pulling images from only public registries and they are required.
# So ALWAYS create this secret!
echo "DBG: kubectl create secret docker-registry image-registry-credentials \\
  --docker-username=\"$DOCKER_REGISTRY_USERNAME\" \\
  --docker-password=\"$DOCKER_REGISTRY_PASSWORD\" \\
  --docker-server=\"$DOCKER_REGISTRY_SERVER\" \\
  -n \"$ROOT_NAMESPACE\""

kubectl create secret docker-registry image-registry-credentials \
  --docker-username="$DOCKER_REGISTRY_USERNAME" \
  --docker-password="$DOCKER_REGISTRY_PASSWORD" \
  --docker-server="$DOCKER_REGISTRY_SERVER" \
  -n "$ROOT_NAMESPACE"
echo ""


## TLS certificates
#TODO: Currently SelfSigned certificates are generated via cert-manager, so no further action need at this moment


# Container registry Certificate Authority
#TODO: Not needed at this moment, so not setup yet and therefore commented out





echo ""
echo ""
echo "---------------------------------------"
echo "Install Korifi"
echo "---------------------------------------"
echo ""

echo "helm install korifi https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz \\
    --namespace=$KORIFI_NAMESPACE  \\
    --set=generateIngressCertificates=true \\
    --set=rootNamespace=$ROOT_NAMESPACE \\
    --set=adminUserName=$ADMIN_USERNAME \\
    --set=api.apiServer.url=api.$BASE_DOMAIN \\
    --set=defaultAppDomainName=apps.$BASE_DOMAIN \\
    --set=containerRepositoryPrefix=europe-docker.pkg.dev/my-project/korifi/ \\
    --set=kpackImageBuilder.builderRepository=europe-docker.pkg.dev/my-project/korifi/kpack-builder \\
    --set=networking.gatewayClass=$GATEWAY_CLASS_NAME \\
    --wait"

helm install korifi "https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz" \
    --namespace="$KORIFI_NAMESPACE" \
    --set=generateIngressCertificates=true \
    --set=rootNamespace="$ROOT_NAMESPACE" \
    --set=adminUserName="$ADMIN_USERNAME" \
    --set=api.apiServer.url="api.$BASE_DOMAIN" \
    --set=defaultAppDomainName="apps.$BASE_DOMAIN" \
    --set=containerRepositoryPrefix=europe-docker.pkg.dev/my-project/korifi/ \
    --set=kpackImageBuilder.builderRepository=europe-docker.pkg.dev/my-project/korifi/kpack-builder \
    --set=networking.gatewayClass="$GATEWAY_CLASS_NAME" \
    --wait
result=$?
if [[ "$result" -ne "0" ]]; then echo "Helm deployment of Korifi cluster failed! Script aborted!"; exit 1; fi

# Wait for all pods in the korifi namespace to be ready
$SUDOCMD kubectl wait --for=condition=Ready pods --all --namespace korifi --timeout=300s

# Verify
assert cf version





echo ""
echo ""
echo "---------------------------------------"
echo "Post Install Configuration"
echo "---------------------------------------"
echo ""


# DNS
echo "Apply DNS and gateway configuration"
# For static gateway
# kubectl get service envoy -n projectcontour -ojsonpath='{.status.loadBalancer.ingress[0]}'
# For dynamic gateway
echo "kubectl get service envoy-korifi -n korifi-gateway -ojsonpath='{.status.loadBalancer.ingress[0]}'"
kubectl get service envoy-korifi -n korifi-gateway -ojsonpath='{.status.loadBalancer.ingress[0]}'
KORIFI_IP=$(kubectl get service envoy-korifi -n korifi-gateway -ojsonpath='{.status.loadBalancer.ingress[0].ip}')
# Add domain to /etc/hosts in case it is not handled at a DNS server
echo ""
echo "Add following to /etc/hosts for every machine you want to access the K8S cluster from:"
echo "${KORIFI_IP}      api.${BASE_DOMAIN}"
echo "${KORIFI_IP}	api.${BASE_DOMAIN}" >>/etc/hosts
echo ""

# Add a HTTPRoute to Kubernetes to use korifi-api
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: korifi-api
  namespace: korifi-gateway
spec:
  parentRefs:
    - name: korifi
      namespace: korifi-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: korifi-api-svc
          namespace: korifi
          port: 443
EOF




## Create certificates for cf-admin
echo "Create certificates for '$ADMIN_USERNAME'"
create_k8s_user_cert "$ADMIN_USERNAME" 



echo ""
echo "---------------------------------------"
echo "Korifi installation complete."
echo "---------------------------------------"
echo "Info:"
echo " - K8S Cluster:	$K8S_CLUSTER_KORIFI"
echo " - K8S Domain:	$(az aks list | jq -r ".[] | select(.name == \"$K8S_CLUSTER_KORIFI\") | .azurePortalFqdn")"
echo " - API endpoint:  api.$BASE_DOMAIN"
echo " - CF Admin:      $ADMIN_USERNAME"
echo " - CS IP:		$KORIFI_IP"
echo "---------------------------------------"
echo ""

##
## Login to Korifi as admin and show some demoe results
##

echo "cf api https://${CF_API_DOMAIN} --skip-ssl-validation"
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
echo "cf login -u ${ADMIN_USERNAME} -a https://${CF_API_DOMAIN} --skip-ssl-validation"
cf login -u "${ADMIN_USERNAME}" -a "https://${CF_API_DOMAIN}" --skip-ssl-validation

# create a default org and default space
cf create-org org
cf create-space -o org space
cf target -o org -s space


#
# End message
#
echo ""
echo "======== Korifi install finished ========"
echo ""
echo ""

