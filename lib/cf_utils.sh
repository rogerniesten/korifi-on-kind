#! /bin/bash
##
## Library with several functions and utils for Korifi
##

set -euo pipefail

## Includes
LIB_PATH=${LIB_PATH:-.}
if [[ ! -f "$LIB_PATH/utils.sh" ]]; then
  echo "[FATAL] Can't load $LIB_PATH/utils.sh! Script aborted"
  exit 99
fi
. "$LIB_PATH/utils.sh"


## Library Functions ########

function adjust_images_to_local_registry() {
  echo "[TRCE] adjust_images_to_local_registry($*) - START"
  local yaml_file=${1?Parameter 'yaml_file' is missing in call to function 'adjust_images_to_local_registry'}
  local image_registries=${2:-$DOCKER_IMAGE_REGISTRY,$GHCR_IMAGE_REGISTRY,$QUAY_IMAGE_REGISTRY,$K8S_IMAGE_REGISTRY}
  local local_registry="${3:-${LOCAL_IMAGE_REGISTRY_FQDN:-}}"
  local override_tag="${4:-}"

  # validate whether yaml_file exists
  assert test -f "$yaml_file"

  if [[ -n "$local_registry" ]]; then
    cp "$yaml_file" "${yaml_file}.bak"
    echo "[DBUG] adjusting for '$image_registries':"

    IFS=',' read -ra registries <<< "$image_registries"
    for image_registry in "${registries[@]}"; do
      echo "[DBUG]   adjusting images for registry '$image_registry' to '${local_registry}/${image_registry}'"
      sed -i "s|${image_registry}/|${local_registry}/${image_registry}/|g" "$yaml_file"
    done

    if [[ -n "$override_tag" ]]; then						# If an override tag is specified, replace all @sha256:... or :<tag> with :<override_tag>
      echo "[DBUG] overriding all digests and tags with ':$override_tag'"	# Replace @sha256:digest with :tag
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

  echo "[INFO] Downloading $filename from $yaml_url"
  curl -sL -o "$local_yaml" "$yaml_url"

  echo "[INFO] Adjusting image references in $filename (if applicable)"
  adjust_images_to_local_registry "$local_yaml"

  echo "[INFO] Applying $filename"
  kubectl apply -f "$local_yaml"
}


function deploy_custom_cluster_builder() {
  echo "[DEBUG] deploy_custom_cluster_builder( '${1:-}', '${2:-}', '${3:-}' ) - START"
  local clusterbuilder_name=${1:-${CLUSTERBUILDER_NAME?Default variable 'CLUSTERBUILDER_NAME' is not set for function 'deploy_custom_cluster_builder'}}
  local image_registry=${2:-${LOCAL_IMAGE_REGISTRY_FQDN:-}}
  local paketo_registry="index.docker.io"

  echo "[DEBUG] LOCAL_IMAGE_REGISTRY_FQDN='${LOCAL_IMAGE_REGISTRY_FQDN:-_notset_}', image_registry='${image_registry:-}'"
  [[ -n "$image_registry" ]] && paketo_registry="${image_registry}/${paketo_registry}"

  echo "[INFO] Deploying custom ClusterBuilder using only images from trusted registry"

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
  
  echo "[INFO] Installing kpack..."
  curl -L -o "$local_kpack_file" "$kpack_release_url"
  adjust_images_to_local_registry "$local_kpack_file" "" "" "$KPACK_VERSION"

  echo "[INFO] Applying CRDs only..."
  # shellcheck disable=SC2002 # yq doesn't always work fine with yq ... file, hence the variant
  kubectl apply -f <(yq e 'select(.kind == "CustomResourceDefinition")' "$local_kpack_file")

  echo "[INFO] Waiting for ClusterLifecycle CRD..."
  until kubectl get crd clusterlifecycles.kpack.io >/dev/null 2>&1; do
    echo -n "."
    sleep 2
  done
  echo " ClusterLifecycle CRD is now available."

  echo "[INFO] Applying kpack release YAML..."
  kubectl apply -f "$local_kpack_file"

  deploy_custom_cluster_builder "$CLUSTERBUILDER_NAME" 

  echo "[INFO] Waiting for kpack pods to be running..."
  kubectl wait --for=condition=Ready pod --all --namespace kpack --timeout=60s
  echo "[INFO] kpack installation done."
  echo ""
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

  echo "[INFO] Creating K8s user '$username'..."
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

  echo "[INFO] K8s user '$username' created."
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
    echo "K8s not using correct cluster ($current_cluster), changing to 'k8s_cluster'..."

    # Try to switch to specified username

    echo " - validate username '$username' against k8s"
    echo "   TRC: assert kubectl config get-contexts | grep \"$username\" >/dev/null"
    assert kubectl config get-contexts | grep "$username" >/dev/null

    echo " - switch to k8s context ${username}"
    echo "   TRC: kubectl config use-context ${username}"
    if ! kubectl config use-context "${username}"; then
      # when failed (e.g. because admin not created yet), use default user
      echo "   TRC: kubectl config use-context ${k8s_prefix}${k8s_cluster}"
      kubectl config use-context "${k8s_prefix}${k8s_cluster}"
    fi

    echo "...done"
  else
    echo "correct K8s cluster is in use ($k8s_cluster)"
  fi
}


function switch_user() {
  local username=${1?Parameter 'username' is missing in call to function 'switch_user'}
  local cf_api_domain=${2:-${CF_API_DOMAIN:?CF_API_DOMAIN not set in call to switch_user()}}

  echo "Switch to user '$username'..."
  # Validate name in k8s
  echo " - validate username '$username' against k8s"
  assert "kubectl config get-contexts -o name | grep -q \"^${username}$\""
  
  # Remark: Is it really required to switch context in k8s?!? If possible, remove it!!
  #         It is required to access the same K8s cluster with both cf and kubectl (if both are used),
  #         so therefore the switch will be made in K8s as well
  
  echo " - switch to k8s context ${username}"
  assert kubectl config use-context "${username}"

  echo " - setting cf api"
  cf api "https://$cf_api_domain" --skip-ssl-validation

  echo " - executing cf auth"
  echo "   cf auth '${username}'"
  cf auth "${username}"

  echo "...done"
}


function add_to_etc_hosts() {
  local add_string="${1?Parameter 'add_string' is missing in call to function 'add_to_etc_hosts'}"
  local search_string="${2:-}"
  local before_or_after="${3:-AFTER}"

  if [[ -z "$search_string" ]]; then
    # add a new line with the given add_string at the end of the file
    if ! grep -qF "$add_string" /etc/hosts; then
      echo "DBG: Adding as new line"
      # shellcheck disable=SC2090
      echo "$add_string" | $SUDOCMD tee -a /etc/hosts >/dev/null
    else
      echo "DBG: Line already existing ($add_string)"
    fi
  else
    # add the add_string to the line(s) where the search_string is found,
    # before or after the search_string
    if ! grep -qF "$add_string" /etc/hosts; then
      echo "DBG: Adding '$add_string' to above mentioned line"
      case "${before_or_after^^}" in
        "BEFORE")
          echo "adding '$add_string' BEFORE '$search_string'"
          # shellcheck disable=SC2090
          $SUDOCMD sed -i "s/$search_string/$add_string $search_string/" /etc/hosts
          ;;
        "AFTER")
          echo "adding '$add_string' AFTER '$search_string'"
          # shellcheck disable=SC2090
          $SUDOCMD sed -i "s/$search_string/$search_string $add_string/" /etc/hosts
          ;;
        *)
          echo "WARNING: Invalid direction '$before_or_after'. No changes made!"
          ;;
      esac
    else
      echo "WARNING: string '$add_string' already present, no need to add"
    fi
    echo ""
  fi
}


function ensure_korifi_ready() {

  ## Verify Service Account and Registry Secret
  echo "🔍 Verifying image-registry-credentials secret..."
  kubectl get secret image-registry-credentials -n cf >/dev/null || {
    echo "[TRACE] kubectl get secret image-registry-credentials -n cf"
    echo "❌ Registry credentials not found in 'cf' namespace"
    exit 1
  }

  echo "🔍 Verifying kpack-service-account uses the correct secret..."
  kubectl get serviceaccount kpack-service-account -n "$ROOT_NAMESPACE" -o jsonpath='{.imagePullSecrets[*].name}' | grep -q image-registry-credentials || {
    echo "[TRACE] kubectl get serviceaccount kpack-service-account -n $ROOT_NAMESPACE -o jsonpath='{.imagePullSecrets[*].name}' | grep -q image-registry-credentials"
    echo "❌ kpack-service-account does not reference image-registry-credentials"
    exit 1
  }

  ## Force ClusterBuilder Reconciliation
  echo "🔁 Forcing ClusterBuilder rebuild..."
  kubectl annotate clusterbuilder "$CLUSTERBUILDER_NAME" "kpack.io/force-rebuild=$(date +%s)" --overwrite

  # Wait for it to become ready (loop with timeout)
  echo "⏳ Waiting for ClusterBuilder to become Ready..."
  local READY=""
  for _ in {1..30}; do
    READY=$(kubectl get clusterbuilder "$CLUSTERBUILDER_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [[ "$READY" == "True" ]] && break
    sleep 5
  done

  [[ "$READY" != "True" ]] && {
    echo "[TRACE] kubectl get clusterbuilder $CLUSTERBUILDER_NAME -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'"
    echo "❌ ClusterBuilder is not ready after timeout"
    exit 1
  }
  echo "✅ ClusterBuilder is ready"

  ## Validate Registry Reachability (optional)
  if [[ -n "$LOCAL_IMAGE_REGISTRY_FQDN" ]]; then
    echo "🌐 Testing access to internal registry..."
    if ! curl -s --connect-timeout 5 "http://${LOCAL_IMAGE_REGISTRY_FQDN}/v2/" >/dev/null; then
      echo "[TRACE] curl -s --connect-timeout 5 http://${LOCAL_IMAGE_REGISTRY_FQDN}/v2/"
      echo "❌ Cannot reach internal image registry"
      exit 1
    fi
  fi

  ## Check BuildTemplates & ClusterStack Are Ready (optional)
  echo "🔍 Checking ClusterStack is ready..."
  if [[ "$(kubectl get clusterstack base-stack -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; then
    echo "[TRACE] kubectl get clusterstack base-stack -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep True"
    echo "❌ ClusterStack 'base-stack' is not ready"
    exit 1
  fi

  echo "🔍 Checking ClusterStore is ready..."
  if [[ "$(kubectl get clusterstore base-store -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; then
    echo "[TRACE] kubectl get clusterstore base-store -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep True"
    echo "❌ ClusterStore not ready"
    exit 1
  fi
}

