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
prompt_if_missing K8S_TYPE "var" "Which K8S type to use? (KIND, AKS)"
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

## First add GPG keys and repo sources

# Helm
curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/helm.gpg > /dev/null # Add the Helm GPG key
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list # Add reqruied repo source for helm
# Cloud Foundry CLI
curl -fsSL https://packages.cloudfoundry.org/debian/cli.cloudfoundry.org.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/cloudfoundry.org.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudfoundry.org.gpg] https://packages.cloudfoundry.org/debian stable main" | sudo tee /etc/apt/sources.list.d/cloudfoundry-cli.list


install_if_missing apt jq jq "jq --version"
install_if_missing apt curl 
install_if_missing apt helm helm "helm version"
install_if_missing apt cf cf8-cli

install_if_missing apt snap snapd
install_if_missing snap yq yq "yq --version"
install_if_missing snap kubectl snap #TODO: requires param --classic !!


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


## TODO: DO SOME CHECKS FOR PREREQUISITS !!!

# Is the specified K8S cluster available?
assert "kubectl config get-clusters | grep ${K8S_CLUSTER_KORIFI}"



##
## Install Korifi cluster
##



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
result=$?
# Wait until all cert-manager pods are ready
echo "Waiting for cert-manager pods to become ready..."
while true; do
  # shellcheck disable=SC2126   # grep -c not possible here as param -v is not combineable with -c
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
# shellcheck disable=SC2002     # due to permissions cat is required
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





echo ""
echo ""
echo "---------------------------------------"
echo "Install Korifi"
echo "---------------------------------------"
echo ""

echo "helm upgrade --install korifi https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz \\
    --namespace=$KORIFI_NAMESPACE  \\
    --set=generateIngressCertificates=true \\
    --set=rootNamespace=$ROOT_NAMESPACE \\
    --set=adminUserName=$ADMIN_USERNAME \\
    --set=api.apiServer.url=$CF_API_DOMAIN \\
    --set=defaultAppDomainName=$CF_APPS_DOMAIN \\
    --set=containerRepositoryPrefix=europe-docker.pkg.dev/my-project/korifi/ \\
    --set=kpackImageBuilder.builderRepository=europe-docker.pkg.dev/my-project/korifi/kpack-builder \\
    --set=networking.gatewayClass=$GATEWAY_CLASS_NAME \\
    --set=networking.gatewayPorts.http=${CF_HTTP_PORT} \\
    --set=networking.gatewayPorts.https=${CF_HTTPS_PORT} \\
    --wait"

helm upgrade --install korifi "https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz" \
    --namespace="$KORIFI_NAMESPACE" \
    --set=generateIngressCertificates=true \
    --set=rootNamespace="$ROOT_NAMESPACE" \
    --set=adminUserName="$ADMIN_USERNAME" \
    --set=api.apiServer.url="$CF_API_DOMAIN" \
    --set=defaultAppDomainName="$CF_APPS_DOMAIN" \
    --set=containerRepositoryPrefix=europe-docker.pkg.dev/my-project/korifi/ \
    --set=kpackImageBuilder.builderRepository=europe-docker.pkg.dev/my-project/korifi/kpack-builder \
    --set=networking.gatewayClass="$GATEWAY_CLASS_NAME" \
    --set=networking.gatewayPorts.http="${CF_HTTP_PORT}" \
    --set=networking.gatewayPorts.https="${CF_HTTPS_PORT}" \
    --wait
    # In KIND following params are set different (https://github.com/cloudfoundry/korifi/releases/latest/download/install-korifi-kind.yaml)
    # TODO: In case of issues in KIND with this install script, concider changing the values of these params
#    --set=api.apiServer.url="localhost" \
#    --set=defaultAppDomainName="apps-127-0-0-1.nip.io" \
#    --set=containerRepositoryPrefix=europe-docker.pkg.dev/my-project/korifi/ \\
#    --set=kpackImageBuilder.builderRepository=europe-docker.pkg.dev/my-project/korifi/kpack-builder \\
    # In KIND following params are set additionally (https://github.com/cloudfoundry/korifi/releases/latest/download/install-korifi-kind.yaml)
    # TODO: In case of issues in KIND with this install script, concider adding
#    --set=logLevel="debug" \
#    --set=debug="false" \
#    --set=stagingRequirements.buildCacheMB="1024" \
#    --set=controllers.taskTTL="5s" \
#    --set=jobTaskRunner.jobTTL="5s" \
#+    --set=networking.gatewayPorts.http="32080" \
#+    --set=networking.gatewayPorts.https="32443" \

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
KORIFI_IP=${KORIFI_IP:-127.0.0.1}	# hose localhost address as backup (for KIND cluster)
assert test -n "$KORIFI_IP"

# Add domain to /etc/hosts in case it is not handled at a DNS server
# For Korifi on a KIND cluster the api is on localhosts, which is already configured in /etc/hosts
echo ""
echo "Add following to /etc/hosts for every machine you want to access the K8S cluster from:"
echo "${KORIFI_IP}	$CF_API_DOMAIN	$CF_APPS_DOMAIN"
echo "${KORIFI_IP}	$CF_API_DOMAIN	$CF_APPS_DOMAIN" >>/etc/hosts
echo "(already done for this machine)"
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
echo " - API endpoint:  $CF_API_DOMAIN"
echo " - CF Admin:      $ADMIN_USERNAME"
echo " - CS IP:		$KORIFI_IP"
echo "---------------------------------------"
echo ""

##
## Login to Korifi as admin and show some demoe results
##

echo "cf api http://${CF_API_DOMAIN}:${CF_HTTP_PORT} --skip-ssl-validation"
cf api "http://${CF_API_DOMAIN}:${CF_HTTP_PORT}" --skip-ssl-validation
echo "cf login -u ${ADMIN_USERNAME} -a http://${CF_API_DOMAIN}:${CF_HTTP_PORT} --skip-ssl-validation"
cf login -u "${ADMIN_USERNAME}" -a "http://${CF_API_DOMAIN}:${HTTP_PORT}" --skip-ssl-validation

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

