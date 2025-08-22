#! /bin/bash
# shellcheck disable=SC2086,SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Installation of a basic Korifi Cluster on AKS (Azure Kubernetes Service)

##

## Includes
. env/.env
. "$LIB_PATH/cf_utils.sh"


##
## Config
##
# logging
export log_level="$LOG_TRC"
export show_timestamp=false
export log_commands_always=true
# korifi
prompt_if_missing K8S_TYPE "var" "Which K8S type to use? (KIND, AKS)"
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. "$ENV_PATH/.env.korifi" || { echo "Config ERROR! Script aborted"; exit 1; }      # read config from environment file
KORIFI_GATEWAY_NAMESPACE=korifi-gateway

# Script should be executed as root (just sudo fails for some commands)
strongly_advice_root



##
## INTERNAL FUNCTIONS
##

function create_gatewayclass() {
  local name="${1:-$GATEWAY_CLASS_NAME}"
  local ctrlname="${2:-projectcontour.io/gateway-controller}"

  log "$LOG_INF" "Create GatewayClass"
  # source: https://projectcontour.io/docs/1.26/guides/gateway-api/
  log "$LOG_CMD" "kubectl apply -f - <<EOF
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

  log "$LOG_INF" "Deploy Configmap for contour and gateway"
  log "$LOG_CMD" "kubectl apply -f - <<EOF
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
  log "$LOG_INF" "Installing cert-manager..."
  kubectl_apply_locally "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml"

  # Wait up to 5 minutes
  kubectl wait --for=condition=ready pod -n cert-manager --all --timeout=300s

  log "$LOG_INF" "✅ All cert-manager pods are ready.\n"
}


## Install Metrics Server
function install_metrics_server_if_missing() {
  if kubectl get pods -A 2>/dev/null | grep -q metrics-server; then
    # Metrics server is already installed implicitly on AKS
    log "$LOG_DBG" "Metrics Server already installed, no action required"
  else
    log "$LOG_INF" "Installing Metrics Server..."
    kubectl_apply_locally "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    log "$LOG_INF" "...done"
  fi
}


function patch_contour_yaml_file() {
  #
  # This function patches a yaml file from the contour deployment to use images from the local registry
  #
  local file=$1

  local CONTOUR_IMAGE_REPO="${LOCAL_IMAGE_REGISTRY_FQDN}/${CONTOUR_CONTOUR_IMAGE}"
  local ENVOY_IMAGE_REPO="${LOCAL_IMAGE_REGISTRY_FQDN}/${CONTOUR_ENVOY_IMAGE}"
  local ENVOY_SERVICE_TYPE="LoadBalancer"

  log "$LOG_INF" "Updating file '$file' to use local registry:"

  # Replace namespace
  log "$LOG_CMD" "  sed -i \"s/namespace: projectcontour/namespace: ${namespace}/g\" $file"
  sed -i "s/namespace: projectcontour/namespace: ${namespace}/g" "$file" || echo "✅ found namespace key & updated to '${namespace}'"

  # Patch contour image
  log "$LOG_CMD" "  sed -i \"s|image: ghcr.io/projectcontour/contour:.*|image: ${CONTOUR_IMAGE_REPO}|g\" $file"
  sed -i "s|image: ghcr.io/projectcontour/contour:.*|image: ${CONTOUR_IMAGE_REPO}|g" "$file" || echo "✅ found contour image key(s) & updated to '${CONTOUR_IMAGE_REPO}'"

  # Patch envoy image
  log "$LOG_CMD" "  sed -i \"s|image: docker.io/envoyproxy/envoy:.*|image: ${ENVOY_IMAGE_REPO}|g\" $file"
  sed -i "s|image: docker.io/envoyproxy/envoy:.*|image: ${ENVOY_IMAGE_REPO}|g" "$file" || echo "✅ found envoy image key(s) & updated to '${ENVOY_IMAGE_REPO}'"

  # Patch Envoy service type if set
  if [[ "$file" == *service-envoy.yaml* ]]; then
    log "$LOG_CMD" "  sed -i \"s/type: ClusterIP/type: ${ENVOY_SERVICE_TYPE}/g\" $file"
    sed -i "s/type: ClusterIP/type: ${ENVOY_SERVICE_TYPE}/g" "$file" || echo "✅ found type key & updated to '${ENVOY_SERVICE_TYPE}'"
  fi
}


function create_cert_secrets_for_contour() {
  # Create a self-signed cert
  log "$LOG_INF" "Create TLS certificates for contour"
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "${tmp:-.}/tls.key" \
    -out "${tmp:-.}/tls.crt" \
    -subj "/CN=contour" \
    -addext "subjectAltName=DNS:contour"

  # Create CA file (self-signed so same as cert)
  cp "$tmp/tls.crt" "$tmp/ca.crt"

  # Create the contourcert secret
  log "$LOG_INF" "Create TLS secret for contour"
  kubectl get secret contourcert --namespace "$namespace" >/dev/null 2>&1 && kubectl delete secret contourcert --namespace "$namespace"       # for idempotency
  kubectl create secret generic contourcert \
    --from-file=ca.crt=${tmp:-.}/ca.crt \
    --from-file=tls.crt=${tmp:-.}/tls.crt \
    --from-file=tls.key=${tmp:-.}/tls.key \
    -n korifi-gateway

  # Create the envoycert secret
  log "$LOG_INF" "Create TLS secret for envy"
  kubectl get secret envoycert --namespace "$namespace" >/dev/null 2>&1 && kubectl delete secret envoycert --namespace "$namespace"       # for idempotency
  kubectl create secret generic envoycert \
    --from-file=ca.crt=${tmp:-.}/ca.crt \
    --from-file=tls.crt=${tmp:-.}/tls.crt \
    --from-file=tls.key=${tmp:-.}/tls.key \
    -n korifi-gateway
}



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
install_if_missing apt helm helm "helm version"
install_if_missing apt cf cf8-cli

install_if_missing apt snap snapd
install_if_missing snap yq yq "yq --version"
install_if_missing snap kubectl snap 
install_if_missing snap go go "go version"

install_pack_if_missing

# Make sure kubenetes user and cf account are in sync
sync_k8s_user "$ADMIN_USERNAME"

## TODO: DO SOME CHECKS FOR PREREQUISITS !!!

# Is the specified K8S cluster available?
assert "kubectl config get-clusters | grep ${K8S_CLUSTER_KORIFI}"



##
## Install Korifi cluster
##



# Namespace creation (TODO: namespaces seem already to be existing, so these command seem to be superfluous and can be removed)
log "$LOG_INF" "Create required namespaces"
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
log "$LOG_INF" ""


# based on: https://github.com/cloudfoundry/korifi/blob/main/INSTALL.md

#
# First install the prerequisits
#
log "$LOG_INF" "

---------------------------------------
Installing prerequisits for Korifi
---------------------------------------
"


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
  local contour_version="${2:-$CONTOUR_VERSION}"

  local USE_CONTOUR_CERT=false


  log "$LOG_INF" "Deploy contour using projectcontour manifest"

  # There are some modifications required to the yaml files, so let's download the required files from the repository
  (
    cd "$tmp" || exit 99
    log "$LOG_INF" "Downloading Contour release source..."
    log "$LOG_CMD" "curl -sSL -o contour-source.tar.gz https://github.com/projectcontour/contour/archive/refs/tags/v${contour_version}.tar.gz"
    curl -sSL -o "contour-source.tar.gz" "https://github.com/projectcontour/contour/archive/refs/tags/v${contour_version}.tar.gz"
    log "$LOG_INF" "tar -xzf contour-source.tar.gz"
    tar -xzf "contour-source.tar.gz"
  )

  # Images need to be pulled from the local registry, namespaces need to adjusted and envoy type should be Loadbalancer.
  # This will be done for each yaml file in function 'patch_contour_yaml_file'
  log "$LOG_INF" "[INFO ] Patching manifest files..."
  src_dir="$tmp/contour-${contour_version}/examples/contour"
  for file in "$src_dir"/*.yaml; do
     patch_contour_yaml_file "$file"
    cat $file | yq >/dev/null || exit 99
  done

  # Some additional adjustments: The certs nee to be removed from args and the gateway-ref must be added
  log "$LOG_INF" "Modify Contour deployment file..."
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

 
  log "$LOG_INF" "Creating namespace $namespace (if it does not exist)..."
  log "$LOG_CMD" "kubectl get namespace $namespace \>/dev/null 2\>&1 \|\| kubectl create namespace \"$namespace"
  kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"

  create_cert_secrets_for_contour

  # === Apply in correct order ===
  log "$LOG_INF" "Applying Contour manifests to namespace '$namespace'..."
  
  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/00-common.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/00-common.yaml"
  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/01-crds.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/01-crds.yaml"
  
  # Use customized configMap instead of the one in the rep.
  create_configmap "$KORIFI_GATEWAY_NAMESPACE"

  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/02-role-contour.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-role-contour.yaml"
  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/02-rbac.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-rbac.yaml"
  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/02-service-contour.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-service-contour.yaml"
  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/02-service-envoy.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/02-service-envoy.yaml"

  if [ "$USE_CONTOUR_CERT" = true ]; then
    log "$LOG_INF" "Applying cert generation job..."
    log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/02-job-certgen.yaml"
    kubectl apply -n "$namespace" -f "$src_dir/02-job-certgen.yaml"
  else
    log "$LOG_DBG" "Skipping cert generation (USE_CONTOUR_CERT=false)"
  fi

  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/03-contour.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/03-contour.yaml"
  log "$LOG_CMD" "kubectl apply -n $namespace -f $src_dir/03-envoy.yaml"
  kubectl apply -n "$namespace" -f "$src_dir/03-envoy.yaml"


  log "$LOG_INF" "Deploy CRDs (GatewayClass, Gateway, HTTPRoute, TLSRoute, etc.)"
  kubectl_apply_locally https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/experimental-install.yaml

  # source: https://projectcontour.io/docs/1.26/guides/gateway-api/
  create_gatewayclass "$GATEWAY_CLASS_NAME"
}


function install_contour_gateway_dynamic() {
  local version=${1:-$CONTOUR_VERSION}

  # contour release url contains only major.minor version (not major.minor.patch), so adjust accordingly if required
  version=$(get_version_levels "$version" 2)

  log "$LOG_INF" "Installing contour gateway (dynamic)..."
  log "$LOG_DBG" "- Contour Gateway Provisioner"

  local contour_release_url="https://raw.githubusercontent.com/projectcontour/contour/release-${version}/examples/render/contour-gateway-provisioner.yaml"
  local local_contour_file="$tmp/contour-gateway-provisioner-v${version}.yaml"

  curl -L -o "$local_contour_file" "$contour_release_url"
  #adjust_images_to_local_registry "$local_contour_file" # not required when external registries are allowed

  log "$LOG_CMD" "kubectl apply -f $local_contour_file"
  kubectl apply -f "$local_contour_file"

  #create_configmap "$KORIFI_GATEWAY_NAMESPACE"

  log "$LOG_DBG" "Waiting for gateway-api-admission-server pod to become ready..."
  kubectl wait --for=condition=ready pod -n gateway-system -l name=gateway-api-admission-server --timeout=120s

  create_gatewayclass "$GATEWAY_CLASS_NAME"
}


case "$DEPLOY_TYPE_CONTOUR" in
  "static")	install_contour_gateway_static "$KORIFI_GATEWAY_NAMESPACE" "$CONTOUR_VERSION";;
  "dynamic")	install_contour_gateway_dynamic ""$CONTOUR_VERSION;;
  *)		die 1 "FAILURE: invalid deployment type '$DEPLOY_TYPE_CONTOUR' for Contour. Script aborted!";;
esac


install_metrics_server_if_missing

log "$LOG_INF" "

---------------------------------------
Pre-install configuration
---------------------------------------
"

## Container registry credentials Secret
log "$LOG_INF" "Container registry credentials Secret"

# First ensure all required vars are populated
# Values will be stored in .env_docker_registry
# For localhost (kind), dummy values are sufficient
prompt_if_missing DOCKER_REGISTRY_SERVER		"var" "Docker Registry Server (e.g. ghcr.io)"					"$DOCKER_REGISTRY_ENV_FILE" 
prompt_if_missing DOCKER_REGISTRY_USERNAME              "var" "Username"								"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_PASSWORD              "var" "Password (for ghcr.io use PAT)"						"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_CONTAINER_REPOSITORY	"var" "Docker Container Registry (e.g. ghcr.io/<your-project>/korifi)"		"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_BUILDER_REPOSITORY	"var" "Docker Builder Registry (e.g. ghcr.io/<your-name>/korifi-kpack-builder"	"$DOCKER_REGISTRY_ENV_FILE" "validate_dummy"

# dummies are sufficient for pulling images from only public registries and they are required.
# So ALWAYS create this secret!
log "$LOG_CMD" "kubectl create secret docker-registry image-registry-credentials \\
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


## TLS certificates
# SelfSigned certificates are generated via cert-manager, so no further action need at this moment


## If a local registry is specified, adjust the KORIFI image names
if [[ -n "${LOCAL_IMAGE_REGISTRY_FQDN:-}" ]]; then
  log "$LOG_INF" "Using images from '$LOCAL_IMAGE_REGISTRY'"
  KORIFI_HELM_HOOKSIMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_HELM_HOOKSIMAGE}"
  KORIFI_API_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_API_IMAGE}"
  KORIFI_CONTROLLERS_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_CONTROLLERS_IMAGE}"
  KORIFI_JOBSTASKRUNNER_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_JOBSTASKRUNNER_IMAGE}"
  KORIFI_KPACKBUILDER_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_KPACKBUILDER_IMAGE}"
  KORIFI_STATEFULSETRUNNER_IMAGE="${LOCAL_IMAGE_REGISTRY_FQDN}/${KORIFI_STATEFULSETRUNNER_IMAGE}"
fi

log "$LOG_CMD" "

---------------------------------------
Install Korifi
---------------------------------------
"

if kubectl get namespace "$KORIFI_GATEWAY_NAMESPACE" >/dev/null 2>&1; then
  # Namespace $KORIFI_GATEWAY_NAMESPACE already exists (probably created in scope of contour deployment)
  kubectl label namespace "$KORIFI_GATEWAY_NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$KORIFI_GATEWAY_NAMESPACE" meta.helm.sh/release-name=korifi --overwrite
  kubectl annotate namespace "$KORIFI_GATEWAY_NAMESPACE" meta.helm.sh/release-namespace="$KORIFI_NAMESPACE" --overwrite
else
  log "$LOG_DBG" "namespace $KORIFI_GATEWAY_NAMESPACE not existing yet, so nothing required to adjust"
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

log "$LOG_CMD" "helm upgrade --install korifi https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz \\
    --namespace=$KORIFI_NAMESPACE
    ${params[*]}
    --wait"

helm upgrade --install korifi \
    "https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz" \
    --namespace="$KORIFI_NAMESPACE" \
    "${params[@]}" \
    --wait || die 1 "Helm deployment of Korifi cluster failed! Script aborted!"

# Wait for all pods in the korifi namespace to be ready
kubectl wait --for=condition=Ready pods --all --namespace korifi --timeout=450s
# Verify
assert cf version




log "$LOG_INF" "

---------------------------------------
Post Install Configuration
---------------------------------------
"


#TODO: Is this needed here? It's already created in function to install contour...
create_configmap "$KORIFI_GATEWAY_NAMESPACE"

log "$LOG_INF" "Apply DNS and gateway configuration"
log "$LOG_CMD" "kubectl get service $ENVOY_SVC -n $KORIFI_GATEWAY_NAMESPACE -ojsonpath='{.status.loadBalancer.ingress[0]}'"
kubectl get service "$ENVOY_SVC" -n "$KORIFI_GATEWAY_NAMESPACE" -ojsonpath='{.status.loadBalancer.ingress[0]}'	# just for info/debugging purposes
KORIFI_IP=$(kubectl get svc "$ENVOY_SVC" -n "$KORIFI_GATEWAY_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
KORIFI_IP=${KORIFI_IP:-::1}  # hose localhost address as backup (for KIND cluster) (Note: IPv6 is used as IPv4 port 443 fails cq. is in use)
assert test -n "$KORIFI_IP"

# Add domain to /etc/hosts in case it is not handled at a DNS server
# For Korifi on a KIND cluster the api is on localhosts, which is already configured in /etc/hosts
log "$LOG_INF" ""
log "$LOG_INF" "Add following to /etc/hosts for every machine you want to access the K8S cluster from (already modified for this machine):
${KORIFI_IP}	$CF_API_DOMAIN  $CF_APPS_DOMAIN # for korifi cluster $K8S_CLUSTER_KORIFI"
if grep "${CF_API_DOMAIN}" /etc/hosts >/dev/null;then
  # replace existing entry
  log "$LOG_CMD" "$SUDOCMD sed -i \"s/.* ${CF_API_DOMAIN}/${KORIFI_IP}	 ${CF_API_DOMAIN}/\" /etc/hosts"
                $SUDOCMD sed -i "s/.* ${CF_API_DOMAIN}/${KORIFI_IP}	 ${CF_API_DOMAIN}/" /etc/hosts
else
  # add new entry
  add_to_etc_hosts "${KORIFI_IP}	 $CF_API_DOMAIN	$CF_APPS_DOMAIN	# for korifi cluster $K8S_CLUSTER_KORIFI"
fi
log "$LOG_INF" ""


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
log "$LOG_INF" "Create certificates for '$ADMIN_USERNAME'"
create_k8s_user_cert "$ADMIN_USERNAME"

# It seems that cf-admin has not the clusterrole cluster-admin, which is required 
# Therefore it will be configure here explicitly
  log "$LOG_INF" "Apply admin authorization for ${ADMIN_USERNAME}"
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
  log "$LOG_INF" "

  As a workaround, K8s port-fording is started:
  
  - for api traffic (port 443):
  
      nohup $SUDOCMD kubectl port-forward -n korifi --address ::1 svc/korifi-api-svc 443:443 >> ${forwarding_logfile} 2>&1 &
  
  - for apps traffic (port $CF_HTTPS_PORT):
  
      nohup $SUDOCMD kubectl port-forward -n $KORIFI_GATEWAY_NAMESPACE --address ::1 svc/envoy-korifi $CF_HTTPS_PORT:$CF_HTTPS_PORT >> ${forwarding_logfile} 2>&1 &
  " 
  echo "$(date): Starting background job for CF API port-forwarding port 443" >> "${forwarding_logfile}"
  echo "$(date): Starting background job for CF APPS port-forwarding port $CF_HTTPS_PORT" >> "${forwarding_logfile}"

  nohup $SUDOCMD kubectl port-forward --kubeconfig ~/.kube/config -n korifi --address ::1 svc/korifi-api-svc 443:443 >> "${forwarding_logfile}" 2>&1 &
  nohup $SUDOCMD kubectl port-forward --kubeconfig ~/.kube/config -n "$KORIFI_GATEWAY_NAMESPACE" --address ::1 svc/envoy-korifi "$CF_HTTPS_PORT:$CF_HTTPS_PORT" >> "${forwarding_logfile}" 2>&1 &
  reset	# reset the terminal as it might be scrambled after the nohup & commands
  log "$LOG_INF" ""
  log "$LOG_INF" "Background processes regarding port forwarding:\n$(pgrep -f -a 'kubectl port-forward')"
  log "$LOG_INF" "Find logs in $(pwd)/forwarding.log"
  log "$LOG_INF" ""
fi





log "$LOG_INF" "
---------------------------------------
Korifi installation complete.
---------------------------------------
Info:
 - K8S Cluster:	$K8S_CLUSTER_KORIFI
 - K8S Domain:	$(az aks list | jq -r ".[] | select(.name == \"$K8S_CLUSTER_KORIFI\") | .azurePortalFqdn")
 - API endpoint:  $CF_API_DOMAIN
 - CF Admin:      $ADMIN_USERNAME
 - CS IP:		$KORIFI_IP
---------------------------------------
"

##
## Login to Korifi as admin and show some demoe results
##

log "$LOG_CMD" "cf api https://${CF_API_DOMAIN} --skip-ssl-validation"
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
log "$LOG_INF" "cf login -u ${ADMIN_USERNAME} -a https://${CF_API_DOMAIN} --skip-ssl-validation"
cf login -u "${ADMIN_USERNAME}" -a "https://${CF_API_DOMAIN}" --skip-ssl-validation

# create a default org and default space
cf create-org org
cf create-space -o org space
cf target -o org -s space


#
# End message
#
log "$LOG_INF" "

======== Korifi install finished ========

"

