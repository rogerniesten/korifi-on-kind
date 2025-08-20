#! /bin/bash
##
## Library with several functions and utils for Korifi
##

set -euo pipefail

## Includes
LIB_PATH=${LIB_PATH:-.}
if [[ ! -f "$LIB_PATH/utils.sh" ]]; then
  die 99 "[FATAL] Can't load $LIB_PATH/utils.sh! Script aborted"
fi
. "$LIB_PATH/utils.sh"


## Library Functions ########

function adjust_images_to_local_registry() {
  log "$LOG_TRC" "adjust_images_to_local_registry($*) - START"
  local yaml_file=${1?Parameter 'yaml_file' is missing in call to function 'adjust_images_to_local_registry'}
  local image_registries=${2:-$DOCKER_IMAGE_REGISTRY,$GHCR_IMAGE_REGISTRY,$QUAY_IMAGE_REGISTRY,$K8S_IMAGE_REGISTRY}
  local local_registry="${3:-${LOCAL_IMAGE_REGISTRY_FQDN:-}}"
  local override_tag="${4:-}"

  # validate whether yaml_file exists
  assert test -f "$yaml_file"

  if [[ -n "$local_registry" ]]; then
    cp "$yaml_file" "${yaml_file}.bak"
    log "$LOG_TRC" "  adjusting for '$image_registries':"

    IFS=',' read -ra registries <<< "$image_registries"
    for image_registry in "${registries[@]}"; do
      log "$LOG_TRC" "  adjusting images for registry '$image_registry' to '${local_registry}/${image_registry}'"
      sed -i "s|${image_registry}/|${local_registry}/${image_registry}/|g" "$yaml_file"
    done

    if [[ -n "$override_tag" ]]; then						# If an override tag is specified, replace all @sha256:... or :<tag> with :<override_tag>
      log "$LOG_TRC" "overriding all digests and tags with ':$override_tag'"	# Replace @sha256:digest with :tag
      sed -i -E "s|@sha256:[a-f0-9]+|:${override_tag}|g" "$yaml_file"		# Replace existing :tag (but not in ports like :8080)
      sed -i -E "s|:([a-zA-Z0-9._-]+)|:${override_tag}|g" "$yaml_file"		# But avoid messing up ports like 8080:80
    fi
  fi
}


function kubectl_apply_locally() {
  local yaml_url=${1?Parameter 'yaml_url' is missing in call to function 'kubectl_apply_locally'}
  local filename
  filename=$(basename "$yaml_url")
  local local_yaml=${2:-$tmp/$filename}

  log "$LOG_INF" "Downloading $filename from $yaml_url"
  curl -sL -o "$local_yaml" "$yaml_url"

  log "$LOG_INF" "Adjusting image references in $filename (if applicable)"
  adjust_images_to_local_registry "$local_yaml"

  log "$LOG_INF" "Applying $filename"
  kubectl apply -f "$local_yaml"
}


function deploy_custom_cluster_builder() {
  log "$LOG_DBG" "deploy_custom_cluster_builder( '${1:-}', '${2:-}', '${3:-}' ) - START"
  local clusterbuilder_name=${1:-${CLUSTERBUILDER_NAME?Default variable 'CLUSTERBUILDER_NAME' is not set for function 'deploy_custom_cluster_builder'}}
  local image_registry=${2:-${LOCAL_IMAGE_REGISTRY_FQDN:-}}
  local paketo_registry="index.docker.io"

  log "$LOG_TRC" "LOCAL_IMAGE_REGISTRY_FQDN='${LOCAL_IMAGE_REGISTRY_FQDN:-_notset_}', image_registry='${image_registry:-}'"
  [[ -n "$image_registry" ]] && paketo_registry="${image_registry}/${paketo_registry}"

  log "$LOG_INF" "Deploying custom ClusterBuilder using only images from trusted registry"

## NOTE: Service account kpack-service-account will be created in namespace $ROOT_NAMESPACE (def
##       cf) in scope of the helm chart of korifi later in this script in.
##       Make sure it's correctly referenced in ClusterStack ClusterStore CluisterBuilder

  # TODO: Use vars for the images (also in install_local_image_registry.sh)
  kubectl delete clusterstack base-stack >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: kpack.io/v1alpha2
kind: ClusterStack
metadata:
  name: base-stack
spec:
  id: io.buildpacks.stacks.jammy
  buildImage:
    image: $paketo_registry/paketobuildpacks/build-jammy-full
  runImage:
    image: $paketo_registry/paketobuildpacks/run-jammy-full
EOF

  kubectl delete clusterstore base-store >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: kpack.io/v1alpha2
kind: ClusterStore
metadata:
  name: base-store
spec:
  sources:
    - image: "$paketo_registry/paketobuildpacks/go"
    - image: "$paketo_registry/paketobuildpacks/java"
    - image: "$paketo_registry/paketobuildpacks/nodejs"
    - image: "$paketo_registry/paketobuildpacks/procfile"
    - image: "$paketo_registry/paketobuildpacks/ruby"
    # Add more as needed
EOF

  kubectl delete clusterbuilder "$clusterbuilder_name" >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: kpack.io/v1alpha2
kind: ClusterBuilder
metadata:
  name: $clusterbuilder_name
spec:
  tag: $DOCKER_REGISTRY_BUILDER_REPOSITORY
  serviceAccountRef:
    name: kpack-service-account
    namespace: $ROOT_NAMESPACE
  stack:
    name: base-stack
    kind: ClusterStack
  store:
    name: base-store
    kind: ClusterStore
  order:
    - group:
        - id: paketo-buildpacks/go
    - group:
        - id: paketo-buildpacks/java
    - group:
        - id: paketo-buildpacks/nodejs
    - group:
        - id: paketo-buildpacks/procfile
    - group:
        - id: paketo-buildpacks/nodejs
EOF
}


function install_kpack() {
  local version=${1:-${KPACK_VERSION?Default variable 'KPACK_VERSION' is not set for function 'install_kpack'}}

  local kpack_release_url="https://github.com/buildpacks-community/kpack/releases/download/v${version}/release-${version}.yaml"
  local local_kpack_file="$tmp/kpack_release-v${version}.yaml"

  # Note: Workaround for kpack installation                                                        <
  #       kpack installation might fail because some CRD's are not installed in time               <
  #       By installing only the CRD parts of kpack first, this issue is bypassed                  <
  
  log "$LOG_INF" "Installing kpack..."
  curl -L -o "$local_kpack_file" "$kpack_release_url"
  adjust_images_to_local_registry "$local_kpack_file" "" "" "$KPACK_VERSION"

  log "$LOG_DBG" " Applying CRDs only..."
  # shellcheck disable=SC2002 # yq doesn't always work fine with yq ... file, hence the variant
  kubectl apply -f <(yq e 'select(.kind == "CustomResourceDefinition")' "$local_kpack_file")

  log "$LOG_DBG" " Waiting for ClusterLifecycle CRD..."
  until kubectl get crd clusterlifecycles.kpack.io >/dev/null 2>&1; do
    echo -n "."
    sleep 2
  done
  log "$LOG_DBG" " ClusterLifecycle CRD is now available."

  log "$LOG_DBG" " Applying kpack release YAML..."
  kubectl apply -f "$local_kpack_file"

  deploy_custom_cluster_builder "$CLUSTERBUILDER_NAME" 

  log "$LOG_DBG" " Waiting for kpack pods to be running..."
  kubectl wait --for=condition=Ready pod --all --namespace kpack --timeout=60s

  log "$LOG_INF" "kpack installation done.\n"
}


function create_k8s_user_cert() {
  local username=${1?Parameter 'username' is missing in call to function 'create_k8s_user_cert'}
  local exp_period=${2:-1w}

  local K8S_CLUSTER csr_encoded exp_period_in_sec

  K8S_CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$(kubectl config current-context)')].context.cluster}")

  local CERT_PATH="${CERT_PATH:-.}"
  local KEY_FILE="$CERT_PATH/${username}.key"
  local CSR_FILE="$CERT_PATH/${username}.csr"
  local CRT_FILE="$CERT_PATH/${username}.crt"

  trap 'echo -n "[TRAP ] Cleaning up cert files..." && rm -f "$KEY_FILE" "$CSR_FILE" "$CRT_FILE" && echo "..done"' RETURN

  log "$LOG_INF" "Creating K8s user '$username'..."
  openssl genrsa -out "$KEY_FILE" 2048
  openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" -subj "/CN=${username}"

  csr_encoded=$(base64 -w 0 "$CSR_FILE")
  exp_period_in_sec=$(duration2sec "$exp_period")

  kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${username}
spec:
  request: ${csr_encoded}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${exp_period_in_sec}
  usages:
    - client auth
EOF

  kubectl certificate approve "$username"
  kubectl get csr "$username" -o jsonpath='{.status.certificate}' | base64 -d > "$CRT_FILE"
  kubectl delete csr "$username"

  kubectl config set-credentials "$username" \
    --client-certificate="$CRT_FILE" \
    --client-key="$KEY_FILE" \
    --embed-certs=true

  kubectl config set-context "$username" \
    --cluster="$K8S_CLUSTER" \
    --user="$username"

  # Create CFUser resource for user                                                                
  # NOTE: newer versions of Korifi, cfusers is no longer a CRD - instead, user access is handled   
  #       differently, often via Kubernetes RoleBindings or a webhook-authenticator plugin.        
  #       Therefore applying cfuser resource is not need (will even fail due to missing resource   
  #       type and will be removed from this script                                                
  #                                                                                                
  #echo "creating cfuser resource for $username in kubernetes..."                                  
  #cat <<EOF >$tmp/user_${username}.yaml                                                           
  #apiVersion: korifi.cloudfoundry.org/v1alpha1                                                    
  #kind: CFUser                                                                                    
  #metadata:                                                                                       
  ##  name: $username                                                                              
  #  namespace: korifi                                                                             
  #spec:                                                                                           
  #  username: $username                                                                           
  #EOF                                                                                             
  #kubectl -f apply $tmp/user_${username}.yaml                                                     

  log "$LOG_INF" "K8s user '$username' created."
}


function sync_k8s_user() {
  local username="${1:-$ADMIN_USERNAME}"
  local k8s_cluster=${2:-$K8S_CLUSTER_KORIFI}
  local k8s_type=${3:-$K8S_TYPE}

  local k8s_prefix current_cluster

  case "${k8s_type^^}" in
    "KIND")     k8s_prefix="kind-" ;;
    "AKS")      k8s_prefix="" ;;
    "*")        echo "WARNING: No valid type provided ($k8s_type), using no prefix (valid: KIND, AKS)"
  esac

  current_cluster=$(kubectl config view --minify | yq '.clusters[0].name')

  if [[ "$current_cluster"  != "${k8s_prefix}${k8s_cluster}" ]];then
    log "$LOG_WRN" "K8s not using correct cluster ($current_cluster), changing to 'k8s_cluster'..."

    # Try to switch to specified username

    log "$LOG_TRC" " - validate username '$username' against k8s"
    log "$LOG_CMD" "   assert kubectl config get-contexts | grep \"$username\" >/dev/null"
    assert kubectl config get-contexts | grep "$username" >/dev/null

    log "$LOG_TRC" " - switch to k8s context ${username}"
    log "$LOG_TRC" "   kubectl config use-context ${username}"
    if ! kubectl config use-context "${username}"; then
      # when failed (e.g. because admin not created yet), use default user
      log "$LOG_WRN" "   Changing config to $username failed! Switching to ${k8s_prefix}${k8s_cluster} instead as fallback"
      log "$LOG_TRC" "   kubectl config use-context ${k8s_prefix}${k8s_cluster}"
      kubectl config use-context "${k8s_prefix}${k8s_cluster}"
    fi

    log "$LOG_INF" "...done"
  else
    log "$LOG_DBG" "correct K8s cluster is in use ($k8s_cluster)"
  fi
}


function switch_user() {
  local username=${1?Parameter 'username' is missing in call to function 'switch_user'}
  local cf_api_domain=${2:-${CF_API_DOMAIN:?CF_API_DOMAIN not set in call to switch_user()}}

  log "$LOG_INF" "Switch to user '$username'..."
  # Validate name in k8s
  log "$LOG_TRC" " - validate username '$username' against k8s"
  assert "kubectl config get-contexts -o name | grep -q \"^${username}$\""
  
  # Remark: Is it really required to switch context in k8s?!? If possible, remove it!!
  #         It is required to access the same K8s cluster with both cf and kubectl (if both are used),
  #         so therefore the switch will be made in K8s as well
  
  log "$LOG_TRC" " - switch to k8s context ${username}"
  assert kubectl config use-context "${username}"

  log "$LOG_TRC" " - setting cf api"
  cf api "https://$cf_api_domain" --skip-ssl-validation

  log "$LOG_TRC" " - executing cf auth"
  log "$LOG_CMD" "   cf auth '${username}'"
  cf auth "${username}"

  log "$LOG_INF" "...done"
}


function add_to_etc_hosts() {
  local add_string="${1?Parameter 'add_string' is missing in call to function 'add_to_etc_hosts'}"
  local search_string="${2:-}"
  local before_or_after="${3:-AFTER}"

  if [[ -z "$search_string" ]]; then
    # add a new line with the given add_string at the end of the file
    if ! grep -qF "$add_string" /etc/hosts; then
      log "$LOG_DBG" "Adding line '$add_string' to /etc/hosts"
      # shellcheck disable=SC2090
      echo "$add_string" | $SUDOCMD tee -a /etc/hosts >/dev/null
    else
      log "$LOG_DBG" "Line '$add_string' already existing in /etc/hosts. No action required."
    fi
  else
    # add the add_string to the line(s) where the search_string is found,
    # before or after the search_string
    if ! grep -qF "$add_string" /etc/hosts; then
      case "${before_or_after^^}" in
        "BEFORE")
          log "$LOG_DBG" "adding '$add_string' BEFORE '$search_string'"
          # shellcheck disable=SC2090
          $SUDOCMD sed -i "s/$search_string/$add_string $search_string/" /etc/hosts
          ;;
        "AFTER")
          log "$LOG_DBG" "adding '$add_string' AFTER '$search_string'"
          # shellcheck disable=SC2090
          $SUDOCMD sed -i "s/$search_string/$search_string $add_string/" /etc/hosts
          ;;
        *)
          die 1 "Invalid direction '$before_or_after' in call to add_to_etc_hosts!"
          ;;
      esac
    else
      log "$LOG_DBG" "Line '$add_string' already existing in /etc/hosts. No action required."
    fi
    echo ""
  fi
}


function ensure_korifi_ready() {

  ## Verify Service Account and Registry Secret
  log "$LOG_DBG" "🔍 Verifying image-registry-credentials secret..."
  log "$LOG_CMD" "kubectl get secret image-registry-credentials -n cf"
  kubectl get secret image-registry-credentials -n cf >/dev/null || die 1 "❌ Registry credentials not found in 'cf' namespace"

  log "$LOG_DBG" "🔍 Verifying kpack-service-account uses the correct secret..."
  log "$LOG_CMD" "kubectl get serviceaccount kpack-service-account -n $ROOT_NAMESPACE -o jsonpath='{.imagePullSecrets[*].name}' | grep -q image-registry-credentials"
  kubectl get serviceaccount kpack-service-account -n "$ROOT_NAMESPACE" -o jsonpath='{.imagePullSecrets[*].name}' | grep -q image-registry-credentials || die 1 "❌ kpack-service-account does not reference image-registry-credentials"

  ## Force ClusterBuilder Reconciliation
  log "$LOG_DBG" "🔁 Forcing ClusterBuilder rebuild..."
  kubectl annotate clusterbuilder "$CLUSTERBUILDER_NAME" "kpack.io/force-rebuild=$(date +%s)" --overwrite

  # Wait for it to become ready (loop with timeout)
  log "$LOG_DBG" "⏳ Waiting for ClusterBuilder to become Ready..."
  log "$LOG_CMD" "kubectl get clusterbuilder $CLUSTERBUILDER_NAME -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'"
  local READY=""
  for _ in {1..30}; do
    READY=$(kubectl get clusterbuilder "$CLUSTERBUILDER_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [[ "$READY" == "True" ]] && break
    sleep 5
  done

  [[ "$READY" != "True" ]] && die 1 "❌ ClusterBuilder is not ready after timeout"
  log "$LOG_INF" "✅ ClusterBuilder is ready"

  ## Validate Registry Reachability (optional)
  if [[ -n "$LOCAL_IMAGE_REGISTRY_FQDN" ]]; then
    log "$LOG_DBG" "🌐 Testing access to internal registry..."
    log "$LOG_CMD" "curl -s --connect-timeout 5 http://${LOCAL_IMAGE_REGISTRY_FQDN}/v2/"
    curl -s --connect-timeout 5 "http://${LOCAL_IMAGE_REGISTRY_FQDN}/v2/" >/dev/null || die 1 "❌ Cannot reach internal image registry"
  fi

  ## Check BuildTemplates & ClusterStack Are Ready (optional)
  log "$LOG_DBG" "🔍 Checking ClusterStack is ready..."
  log "$LOG_CMD" "kubectl get clusterstack base-stack -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep True"
  if [[ "$(kubectl get clusterstack base-stack -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; then
    die 1 "❌ ClusterStack 'base-stack' is not ready"
  fi

  log "$LOG_DBG" "🔍 Checking ClusterStore is ready..."
  log "$LOG_CMD" "kubectl get clusterstore base-store -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep True"
  if [[ "$(kubectl get clusterstore base-store -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; then
    die 1 "❌ ClusterStore not ready"
  fi
}

