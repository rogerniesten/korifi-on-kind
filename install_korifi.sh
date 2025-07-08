#! /bin/bash
# shellcheck disable=SC2086,SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
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

export KORIFI_GATEWAY_NAMESPACE=korifi-gateway
export KORIFI_GATEWAY_DEPLOYMENT=contour-korifi

# Script should be executed as root (just sudo fails for some commands)
strongly_advice_root 5



##
## INTERNAL FUNCTIONS
##

function create_gatewayclass() {
  local name="${1:-$GATEWAY_CLASS_NAME}"
  local ctrlname="${2:-projectcontour.io/gateway-controller}"

  echo "[INFO ] Create GatewayClass"
  # source: https://projectcontour.io/docs/1.26/guides/gateway-api/
  echo "[TRACE] kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: GatewayClass
metadata:
  name: ${name}
spec:
  controllerName: ${ctrlname}
EOF"
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: GatewayClass
metadata:
  name: ${name}
spec:
  controllerName: ${ctrlname}
EOF
}

function create_configmap() {
  local namespace="${1:-$KORIFI_GATEWAY_NAMESPACE}"

  echo "[INFO ] Deploy Configmap for contour and gateway"
  echo "[TRACE] kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: contour
  namespace: $namespace
data:
  contour.yaml: |
    gateway:
      controllerName: projectcontour.io/gateway-controller
    disablePermitInsecure: false
    accesslog-format: envoy
EOF"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: contour
  namespace: $namespace
data:
  contour.yaml: |
    gateway:
      controllerName: projectcontour.io/gateway-controller
    disablePermitInsecure: false
    accesslog-format: envoy
EOF
}


## Install Cert Manager
function install_cert_manager() {
  echo "Installing cert-manager..."
  kubectl_apply_locally "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml"

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
}


## Install Metrics Server
function install_metrics_server_if_missing() {
  kubectl get pods -A | grep metrics-server 1>/dev/null
  metrics_server_installed=$?
  if [[ $metrics_server_installed -eq 0 ]]; then
    # Metrics server is already installed implicitly on AKS
    echo "Metrics Server already installed, no action required"
  else
    echo "Installing Metrics Server..."
    kubectl_apply_locally "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    echo "...done"
  fi
}


function patch_file() {
  #
  # This function patches a yaml file from the contour deployment to use images from the local registry
  #
  local file=$1

  local CONTOUR_IMAGE_REPO="${LOCAL_IMAGE_REGISTRY_FQDN}/${CONTOUR_CONTOUR_IMAGE}"
  local ENVOY_IMAGE_REPO="${LOCAL_IMAGE_REGISTRY_FQDN}/${CONTOUR_ENVOY_IMAGE}"
  local ENVOY_SERVICE_TYPE="LoadBalancer"

  # Replace namespace
  echo "[TRACE]   sed -i \"s/namespace: projectcontour/namespace: ${namespace}/g\" $file"
  sed -i "s/namespace: projectcontour/namespace: ${namespace}/g" "$file" || echo "found & updated"
  test $? && echo "found & updated"

  # Patch contour image
  echo "[TRACE]   sed -i \"s|image: ghcr.io/projectcontour/contour:.*|image: ${CONTOUR_IMAGE_REPO}|g\" $file"
  sed -i "s|image: ghcr.io/projectcontour/contour:.*|image: ${CONTOUR_IMAGE_REPO}|g" "$file" || echo "found & updated"

  # Patch envoy image
  echo "[TRACE]   sed -i \"s|image: docker.io/envoyproxy/envoy:.*|image: ${ENVOY_IMAGE_REPO}|g\" $file"
  sed -i "s|image: docker.io/envoyproxy/envoy:.*|image: ${ENVOY_IMAGE_REPO}|g" "$file" || echo "found & updated"

  # Patch Envoy service type if set
  if [[ "$file" == *service-envoy.yaml* ]]; then
    echo "[TRACE]   sed -i \"s/type: ClusterIP/type: ${ENVOY_SERVICE_TYPE}/g\" $file"
    sed -i "s/type: ClusterIP/type: ${ENVOY_SERVICE_TYPE}/g" "$file" || echo "found & updated"
  fi
}

function create_cert_secrets_for_contour() {
  # Create a self-signed cert
  echo "[INFO] Create TLS certificates for contour"
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$tmp/tls.key" \
    -out "$tmp/tls.crt" \
    -subj "/CN=contour" \
    -addext "subjectAltName=DNS:contour"

  # Create CA file (self-signed so same as cert)
  cp "$tmp/tls.crt" "$tmp/ca.crt"

  # Create the contourcert secret
  echo "[INFO] Create TLS secret for contour"
  kubectl get secret contourcert --namespace "$namespace" >/dev/null 2>&1 && kubectl delete secret contourcert --namespace "$namespace"       # for idempotency
  kubectl create secret generic contourcert \
   --from-file=ca.crt=$tmp/ca.crt \
   --from-file=tls.crt=$tmp/tls.crt \
   --from-file=tls.key=$tmp/tls.key \
   -n korifi-gateway

  # Create the envoycert secret
  echo "[INFO] Create TLS secret for envy"
  kubectl get secret envoycert --namespace "$namespace" >/dev/null 2>&1 && kubectl delete secret envoycert --namespace "$namespace"       # for idempotency
  kubectl create secret generic envoycert \
    --from-file=ca.crt=$tmp/ca.crt \
    --from-file=tls.crt=$tmp/tls.crt \
    --from-file=tls.key=$tmp/tls.key \
    -n korifi-gateway
}



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
install_if_missing snap kubectl snap 

install_go_if_missing "${GO_VERSION}"

# Make sure kubenetes user and cf account are in sync
sync_k8s_user "$ADMIN_USERNAME"

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


## Install cert manager
install_cert_manager


## Install kpack
install_kpack "$KPACK_VERSION"


## Install Contour Gateway
function install_contour_gateway_static() {
##
## This function uses projectcontour Helmchart for deploying Contour
##
## Unfortunately projectcontour doesn't provide or maintain helm charts anymore, so
## we can't use a values.yaml to update the deployment. Instead we have to update
## the plain yaml files using sed.
##

  local namespace="${1:-$KORIFI_GATEWAY_NAMESPACE}"
  local image_registry=${2:-$LOCAL_IMAGE_REGISTRY_FQDN}
  local contour_version="${3:-$CONTOUR_VERSION}"

  local USE_CONTOUR_CERT=false


  echo "[INFO] Deploy contour using projectcontour manifest"

  # There are some modifications required to the yaml files, so let's download the required files from the repository
  (
    cd "$tmp" || exit 99
    echo "[INFO ] Downloading Contour release source..."
    echo "[TRACE] curl -sSL -o contour-source.tar.gz https://github.com/projectcontour/contour/archive/refs/tags/v${contour_version}.tar.gz"
    curl -sSL -o "contour-source.tar.gz" "https://github.com/projectcontour/contour/archive/refs/tags/v${contour_version}.tar.gz"
    echo "[TRACE] tar -xzf contour-source.tar.gz"
    tar -xzf "contour-source.tar.gz"
  )

  # Images need to be pulled from the local registry, namespaces need to adjusted and envoy type should be Loadbalancer.
  # This will be done for each yaml file in function 'patch_file'
  echo "[INFO ] Patching manifest files..."
  src_dir="$tmp/contour-${contour_version}/examples/contour"
  for file in "$src_dir"/*.yaml; do
    patch_file "$file"
    cat $file | yq >/dev/null || exit 99
  done

  # Some additional adjustments: The certs nee to be removed from args and the gateway-ref must be added
  echo "[INFO ] Modify Contour deployment file..."
  # Remove from .spec.tempate.spec.containers[contour].args:
  #   --contour-cafile=/certs/ca.crt
  #   --contour-cert-file=/certs/tls.crt
  #   --contour-key-file=/certs/tls.key
  # Add to .spec.tempate.spec.containers[contour].args:
  #   --gateway-ref=projectcontour.io/gateway-controller
  yq -i '
  (.spec.template.spec.containers[] | select(.name == "contour").args) |=
    map(select(. != "--contour-cafile=/certs/ca.crt" and
               . != "--contour-cert-file=/certs/tls.crt" and
               . != "--contour-key-file=/certs/tls.key"))' "${src_dir}/03-contour.yaml"

 
  echo "[INFO ] Creating namespace $namespace (if it does not exist)..."
  echo "[TRACE] kubectl get namespace $namespace \>/dev/null 2\>&1 \|\| kubectl create namespace \"$namespace"
  kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"

  create_cert_secrets_for_contour

  # === Apply in correct order ===
  echo "[INFO ] Applying Contour manifests to namespace '$namespace'..."
  
  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/00-common.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/00-common.yaml"
  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/01-crds.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/01-crds.yaml"
  
  # Use customized configMap instead of the one in the rep.
  create_configmap "$KORIFI_GATEWAY_NAMESPACE"

  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/02-role-contour.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-role-contour.yaml"
  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/02-rbac.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-rbac.yaml"
  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/02-service-contour.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-service-contour.yaml"
  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/02-service-envoy.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-service-envoy.yaml"

  if [ "$USE_CONTOUR_CERT" = true ]; then
    echo "[INFO ] Applying cert generation job..."
    echo "[TRACE] kubectl apply -n $namespace -f $src_dir/02-job-certgen.yaml"
    kubectl apply -n "$namespace" -f "$src_dir/02-job-certgen.yaml"
  else
    echo "[INFO ] Skipping cert generation (USE_CONTOUR_CERT=false)"
  fi

  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/03-contour.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/03-contour.yaml"
  echo "[TRACE] kubectl apply -n $namespace -f $src_dir/03-envoy.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/03-envoy.yaml"


  echo "[INFO ] Deploy CRDs (GatewayClass, Gateway, HTTPRoute, TLSRoute, etc.)"
  kubectl_apply_locally https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/experimental-install.yaml

  # source: https://projectcontour.io/docs/1.26/guides/gateway-api/
  create_gatewayclass "$GATEWAY_CLASS_NAME"
}


function install_contour_gateway_dynamic() {
  local version=${1:-$CONTOUR_VERSION}

  # contour release url contains only major.minor version (not major.minor.patch), so adjust accordingly if required
  version=$(get_version_levels "$version" 2)

  echo "Installing contour gateway (dynamic)..."
  echo "- Contour Gateway Provisioner"

  local contour_release_url="https://raw.githubusercontent.com/projectcontour/contour/release-${version}/examples/render/contour-gateway-provisioner.yaml"
  local local_contour_file="$tmp/contour-gateway-provisioner-v${version}.yaml"

  curl -L -o "$local_contour_file" "$contour_release_url"
  #adjust_images_to_local_registry "$local_contour_file" # not required when external registries are allowed

  echo "TRC: kubectl apply -f $local_contour_file"
  kubectl apply -f "$local_contour_file"

  #create_configmap "$KORIFI_GATEWAY_NAMESPACE"

  echo "Waiting for gateway-api-admission-server pod to become ready..."
  kubectl wait --for=condition=ready pod -n gateway-system -l name=gateway-api-admission-server --timeout=120s

  create_gatewayclass "$GATEWAY_CLASS_NAME"
}


case "$DEPLOY_TYPE_CONTOUR" in
  "static")	install_contour_gateway_static "$KORIFI_GATEWAY_NAMESPACE" "$LOCAL_IMAGE_REGISTRY_FQDN" "$CONTOUR_VERSION";;
  "dynamic")	install_contour_gateway_dynamic ""$CONTOUR_VERSION;;
  *)		echo "FAILURE: invalid deployment type '$DEPLOY_TYPE_CONTOUR' for Contour. Script aborted!";;
esac


install_metrics_server_if_missing

echo ""
echo ""
echo "---------------------------------------"
echo "Pre-install configuration"
echo "---------------------------------------"
echo ""

## Container registry credentials Secret
echo "Container registry credentials Secret"

# First ensure all required vars are populated
# Values will be stored in .env_docker_registry
# For localhost (kind), dummy values are sufficient
prompt_if_missing DOCKER_REGISTRY_SERVER		"var" "Docker Registry Server (e.g. ghcr.io)"					"$DOCKER_REGISTRY_ENV_FILE" 
prompt_if_missing DOCKER_REGISTRY_USERNAME              "var" "Username"								"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_PASSWORD              "var" "Password (for ghcr.io use PAT)"						"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_CONTAINER_REPOSITORY	"var" "Docker Container Registry (e.g. ghcr.io/rogerniesten/korifi)"		"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_BUILDER_REPOSITORY	"var" "Docker Builder Registry (e.g. ghcr.io/rogerniesten/korifi-kpack-builder"	"$DOCKER_REGISTRY_ENV_FILE" "validate_dummy"

# dummies are sufficient for pulling images from only public registries and they are required.
# So ALWAYS create this secret!
echo "DBG: kubectl create secret docker-registry image-registry-credentials \\
  --docker-username=\"$DOCKER_REGISTRY_USERNAME\" \\
  --docker-password=\"${DOCKER_REGISTRY_PASSWORD:1:4}**********\" \\
  --docker-server=\"$DOCKER_REGISTRY_SERVER\" \\
  -n \"$ROOT_NAMESPACE\""
kubectl get secret image-registry-credentials -n "$ROOT_NAMESPACE" >/dev/null 2>&1 && kubectl delete secret image-registry-credentials -n "$ROOT_NAMESPACE" --ignore-not-found	# for idempotency
kubectl create secret docker-registry image-registry-credentials \
  --docker-username="$DOCKER_REGISTRY_USERNAME" \
  --docker-password="$DOCKER_REGISTRY_PASSWORD" \
  --docker-server="$DOCKER_REGISTRY_SERVER" \
  --docker-email="dummy@dummy.com" \
  -n "$ROOT_NAMESPACE"
echo ""


## TLS certificates
# SelfSigned certificates are generated via cert-manager, so no further action need at this moment


## If a local registry is specified, adjust the KORIFI image names
if [[ -n "${LOCAL_IMAGE_REGISTRY_FQDN:-}" ]]; then
  echo "[INFO] Using images from '$LOCAL_IMAGE_REGISTRY'"
  KORIFI_HELM_HOOKSIMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_HELM_HOOKSIMAGE}"
  KORIFI_API_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_API_IMAGE}"
  KORIFI_CONTROLLERS_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_CONTROLLERS_IMAGE}"
  KORIFI_JOBSTASKRUNNER_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_JOBSTASKRUNNER_IMAGE}"
  KORIFI_KPACKBUILDER_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_KPACKBUILDER_IMAGE}"
  KORIFI_STATEFULSETRUNNER_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_STATEFULSETRUNNER_IMAGE}"
fi

echo ""
echo ""
echo "---------------------------------------"
echo "Install Korifi"
echo "---------------------------------------"
echo ""

if kubectl get namespace "$KORIFI_GATEWAY_NAMESPACE" >/dev/null 2>&1; then
  # Namespace $KORIFI_GATEWAY_NAMESPACE already exists (probably created in scope of contour deployment)
  kubectl label namespace "$KORIFI_GATEWAY_NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$KORIFI_GATEWAY_NAMESPACE" meta.helm.sh/release-name=korifi --overwrite
  kubectl annotate namespace "$KORIFI_GATEWAY_NAMESPACE" meta.helm.sh/release-namespace="$KORIFI_NAMESPACE" --overwrite
else
  echo "[DEBUG] namespace $KORIFI_GATEWAY_NAMESPACE not existing yet, so nothing required to adjust"
fi

params=(
    --set=generateIngressCertificates=true
    --set=rootNamespace="$ROOT_NAMESPACE"
    --set=adminUserName="$ADMIN_USERNAME"
    --set=api.apiServer.url="$CF_API_DOMAIN"
    --set=defaultAppDomainName="$CF_APPS_DOMAIN"
    --set=containerRepositoryPrefix="$DOCKER_REGISTRY_CONTAINER_REPOSITORY"	# base repo path where application images built by korifi are stored
    --set=kpackImageBuilder.builderRepository="$DOCKER_REGISTRY_BUILDER_REPOSITORY" # builder image that kpack uses as env to build application images 
    --set=networking.gatewayClass="$GATEWAY_CLASS_NAME"
    --set=networking.gatewayPorts.http="${CF_HTTP_PORT}"
    --set=networking.gatewayPorts.https="${CF_HTTPS_PORT}"
    --set=experimental.managedServices.enabled=true				# is required to use next parameter
    --set=experimental.managedServices.trustInsecureBrokers=true		# is required when local registry is used
    # The images below are explicitly specified public or locally, depending on deployment type
    --set=helm.hooksImage="${KORIFI_HELM_HOOKSIMAGE}"
    --set=api.image="${KORIFI_API_IMAGE}"
    --set=controllers.image="${KORIFI_CONTROLLERS_IMAGE}"
    --set=jobTaskRunner.image="${KORIFI_JOBSTASKRUNNER_IMAGE}"
    --set=kpackImageBuilder.image="${KORIFI_KPACKBUILDER_IMAGE}"
    --set=statefulsetRunner.image="${KORIFI_STATEFULSETRUNNER_IMAGE}"
    --set=kpackImageBuilder.createClusterBuilder=false
    --set=kpackImageBuilder.clusterBuilderName="${CLUSTERBUILDER_NAME}"
    # Some additional variables that can be set
#    --set=logLevel="debug" \
#    --set=debug="false" \
#    --set=stagingRequirements.buildCacheMB="1024" \
#    --set=controllers.taskTTL="5s" \
#    --set=jobTaskRunner.jobTTL="5s" \
)

echo "[TRACE] helm upgrade --install korifi https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz \\
    --namespace=$KORIFI_NAMESPACE \\"
printf '    %s \\\n' "${params[@]}"
echo "    --wait"

helm upgrade --install korifi "https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz" \
    --namespace="$KORIFI_NAMESPACE" \
    "${params[@]}" \
    --wait

result=$?
if [[ "$result" -ne "0" ]]; then echo "Helm deployment of Korifi cluster failed! Script aborted!"; exit 1; fi


# Wait for all pods in the korifi namespace to be ready
kubectl wait --for=condition=Ready pods --all --namespace korifi --timeout=450s
# Verify
assert cf version





echo ""
echo ""
echo "---------------------------------------"
echo "Post Install Configuration"
echo "---------------------------------------"
echo ""


#TODO: Is this needed here? It's already created in function to install contour...
create_configmap "$KORIFI_GATEWAY_NAMESPACE"

echo "Apply DNS and gateway configuration"
echo "kubectl get service $ENVOY_SVC -n $KORIFI_GATEWAY_NAMESPACE -ojsonpath='{.status.loadBalancer.ingress[0]}'"
kubectl get service "$ENVOY_SVC" -n "$KORIFI_GATEWAY_NAMESPACE" -ojsonpath='{.status.loadBalancer.ingress[0]}'	# just for info/debugging purposes
KORIFI_IP=$(kubectl get svc "$ENVOY_SVC" -n "$KORIFI_GATEWAY_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
KORIFI_IP=${KORIFI_IP:-::1}  # hose localhost address as backup (for KIND cluster) (Note: IPv6 is used as IPv4 port 443 fails cq. is in use)
assert test -n "$KORIFI_IP"

# Add domain to /etc/hosts in case it is not handled at a DNS server
# For Korifi on a KIND cluster the api is on localhosts, which is already configured in /etc/hosts
echo ""
echo "Add following to /etc/hosts for every machine you want to access the K8S cluster from:"
echo "${KORIFI_IP}	$CF_API_DOMAIN  $CF_APPS_DOMAIN # for korifi cluster $K8S_CLUSTER_KORIFI"
if grep "${CF_API_DOMAIN}" /etc/hosts >/dev/null;then
  # replace existing entry
  echo "[TRACE] $SUDOCMD sed -i \"s/.* ${CF_API_DOMAIN}/${KORIFI_IP}	 ${CF_API_DOMAIN}/\" /etc/hosts"
                $SUDOCMD sed -i "s/.* ${CF_API_DOMAIN}/${KORIFI_IP}	 ${CF_API_DOMAIN}/" /etc/hosts
  echo "(already modified for this machine)"
else
  # add new entry
  add_to_etc_hosts "${KORIFI_IP}	 $CF_API_DOMAIN	$CF_APPS_DOMAIN	# for korifi cluster $K8S_CLUSTER_KORIFI"
  echo "(already added for this machine)"
fi
echo ""


# Add a HTTPRoute to Kubernetes to use korifi-api
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: korifi-api
  namespace: $KORIFI_GATEWAY_NAMESPACE
spec:
  parentRefs:
    - name: korifi
      namespace: $KORIFI_GATEWAY_NAMESPACE
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

# It seems that cf-admin has not the clusterrole cluster-admin, which is required 
# Therefore it will be configure here explicitly
  echo "Apply admin authorization for ${ADMIN_USERNAME}"
  ## apply korifi-admin role to cf-admin
  kubectl apply -f - <<EOF
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: ${ADMIN_USERNAME}-binding
  subjects:
  - kind: User
    name: ${ADMIN_USERNAME}  # <-- must match CN in certificate!
    apiGroup: rbac.authorization.k8s.io
  roleRef:
    kind: ClusterRole
    name: cluster-admin
    apiGroup: rbac.authorization.k8s.io
EOF



# Workaround for KIND
# ===================
# The cf api nor k8s load balancer (for apps) is reachable from the host
# As a workaround, let's run a background process to handle the port forwarding. 
if [[ "${K8S_TYPE^^}" == "KIND" ]];then
  forwarding_logfile=forwarding_$(date +"%y%m%d-%H%M").log
  touch "$forwarding_logfile"
  echo ""
  echo "As a workaround, K8s port-fording is started:"
  echo ""
  echo "- for api traffic (port 443):"
  echo ""
  echo "    nohup $SUDOCMD kubectl port-forward -n korifi --address ::1 svc/korifi-api-svc 443:443 >> ${forwarding_logfile} 2>&1 &"
  echo ""
  echo "- for apps traffic (port $CF_HTTPS_PORT):"
  echo ""
  echo "    nohup $SUDOCMD kubectl port-forward -n $KORIFI_GATEWAY_NAMESPACE --address ::1 svc/envoy-korifi $CF_HTTPS_PORT:$CF_HTTPS_PORT >> ${forwarding_logfile} 2>&1 &"
  echo ""
  echo "$(date): Starting background job for CF API port-forwarding port 443" >> "${forwarding_logfile}"
  echo "$(date): Starting background job for CF APPS port-forwarding port $CF_HTTPS_PORT" >> "${forwarding_logfile}"
  nohup $SUDOCMD kubectl port-forward --kubeconfig ~/.kube/config -n korifi --address ::1 svc/korifi-api-svc 443:443 >> "${forwarding_logfile}" 2>&1 &
  nohup $SUDOCMD kubectl port-forward --kubeconfig ~/.kube/config -n "$KORIFI_GATEWAY_NAMESPACE" --address ::1 svc/envoy-korifi "$CF_HTTPS_PORT:$CF_HTTPS_PORT" >> "${forwarding_logfile}" 2>&1 &
  reset	# reset the terminal as it might be scrambled after the nohup & commands
  echo ""
  echo "Background processes regarding port forwarding:"
  pgrep -f -a 'kubectl port-forward'
  echo "Find logs in $(pwd)/forwarding.log"
  echo ""
fi





echo ""
echo "---------------------------------------"
echo "Korifi installation complete."
echo "---------------------------------------"
echo "Info:"
echo " - K8S Cluster:	$K8S_CLUSTER_KORIFI"
#echo " - K8S Domain:	$(az aks list | jq -r ".[] | select(.name == \"$K8S_CLUSTER_KORIFI\") | .azurePortalFqdn")"
echo " - API endpoint:  $CF_API_DOMAIN"
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

