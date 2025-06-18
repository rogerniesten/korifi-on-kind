#! /bin/bash
##
## Library with several functions and utils for Korifi
##
#set -euo pipefail

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"


function adjust_images_to_local_registry() {
  echo "[TRCE] adjust_image_to_local_registry($*) - START"
  local yaml_file=$1
  local image_registries=${2:-$DOCKER_IMAGE_REGISTRY,$GHCR_IMAGE_REGISTRY,$QUAY_IMAGE_REGISTRY}
  local local_registry="${3:-$LOCAL_IMAGE_REGISTRY_FQDN}"
  local override_tag="${4:-}"

  # validate whether yaml_file exists
  assert test -f "$yaml_file"

  if [[ -n "${local_registry:-}" ]];then
    cp "$yaml_file" "${yaml_file}.bak"
    echo "[DBUG] adjusting for '$image_registries':"
    while [[ $image_registries ]]; do
      image_registry=${image_registries%%,*}
      echo "[DBUG]   ajdjusting images for registry '$image_registry' to '${local_registry}/${image_registry}'"
      sed -i "s|${image_registry}/|${local_registry}/${image_registry}/|g" "$yaml_file"
  
      # Remove the first registry from the list
      if [[ $image_registries == *,* ]]; then
        image_registries=${image_registries#*,}
      else
        image_registries=""
      fi
      echo "[DBUG]   remaining registries: '$image_registries'"
    done

    # If an override tag is specified, replace all @sha256:... or :<tag> with :<override_tag>
    if [[ -n "$override_tag" ]]; then
      echo "[DBUG] overriding all digests and tags with ':$override_tag'"
      # Replace @sha256:digest with :tag
      sed -i -E "s|@sha256:[a-f0-9]+|:${override_tag}|g" "$yaml_file"
      # Replace existing :tag (but not in ports like :8080)
      sed -i -E "s|:([a-zA-Z0-9._-]+)|:${override_tag}|g" "$yaml_file"
      # But avoid messing up ports like 8080:80
      sed -i -E "s|([0-9]+):${override_tag}|\\1|g" "$yaml_file"
    fi

  fi
}


## Install kpack
function install_kpack() {
  local version=${1:-$KPACK_VERSION}

  local kpack_release_url="https://github.com/buildpacks-community/kpack/releases/download/v${version}/release-${version}.yaml"
  local local_kpack_file="$tmp/kpack_release-v${version}.yaml"
  
  # Note: Workaround for kpack installation
  #       kpack installation might fail because some CRD's are not installed in time
  #       By installing only the CRD parts of kpack first, this issue is bypassed

  echo "Installing kpack..."

  curl -L -o "$local_kpack_file" "$kpack_release_url"
  adjust_images_to_local_registry "$local_kpack_file" "" "" "$KPACK_VERSION"

  # Step 1: Apply only CRDs (initial apply to install CRDs)
  #< echo "TRC: kubectl apply -f <(wget -qO- $local_kpack_file | yq e 'select(.kind == \"CustomResourceDefinition\")')"
  #< kubectl apply -f <(wget -qO- "$local_kpack_file" | yq e 'select(.kind == "CustomResourceDefinition")')
  echo "TRC: kubectl apply -f <(cat "$local_kpack_file" | yq e 'select(.kind == \"CustomResourceDefinition\")')"
  kubectl apply -f <(cat "$local_kpack_file" | yq e 'select(.kind == "CustomResourceDefinition")')


  # Step 2: Wait for ClusterLifecycle CRD to become available
  echo "Waiting for ClusterLifecycle CRD to be registered..."
  until kubectl get crd clusterlifecycles.kpack.io >/dev/null 2>&1; do
    echo -n "."
    sleep 2
  done
  echo "ClusterLifecycle CRD is now available."

  # Step 3: Apply the release again to ensure all resources are created
  echo "TRC: kubectl apply --filename \"$local_kpack_file\""
  kubectl apply --filename "$local_kpack_file"

  # Step 4: Verify kpack
  echo "Waiting for kpack pods are running..."
  kubectl wait --for=jsonpath='{.status.phase}'=Running pod --all --namespace kpack --timeout=60s
  echo "...done"
  echo ""
}


function create_k8s_user_cert() {
  local username=$1
  local exp_period=${2:-1w}

  local K8S_CLUSTER csr_encoded exp_period_in_sec

  # retrieve the name of the current Kubernetes Cluster
  K8S_CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$(kubectl config current-context)')].context.cluster}")
  # Set the certificate filenames
  local CERT_PATH="${CERT_PATH:-.}"
  local KEY_FILE="$CERT_PATH/${username}.key"
  local CSR_FILE="$CERT_PATH/${username}.csr"
  local CRT_FILE="$CERT_PATH/${username}.crt"

  # ensure cert files are removed when leaving this function
  trap 'rm -f "$KEY_FILE" "$CSR_FILE" "CRT_FILE"' EXIT

  echo "Create K8s user '$username'..."
  # Create certificate for user
  echo " - Create certificate for user $username"
  openssl genrsa -out "$KEY_FILE" 2048
  openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "/CN=${username}"

  # Request and sign the CSR with the Kubernetes CA
  csr_encoded=$(base64 -w 0 "$CSR_FILE")
  exp_period_in_sec=$(duration2sec "$exp_period")
  echo " - Request the CSR with the Kubernetes CA"
  #echo "   DBG: csr file content:"
  #cat "$CSR_FILE"
  #echo "   DBG: encoded csr:"
  #echo "$csr_encoded"
  # Create the signing request
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

  # approve the signing request
  echo " - approve signing request"
  echo "   kubectl certificate approve ${username}"
  kubectl certificate approve "$username"

  echo " - retrieve the CRT"
  echo "   kubectl get csr ${username} -o jsonpath='{.status.certificate}' | base64 -d > ${CRT_FILE}"
  kubectl get csr "${username}" -o jsonpath='{.status.certificate}' | base64 -d > "${CRT_FILE}"

  # This is required to prevent reuse of an old CSR (and ending up with Key and CRT not matching)
  echo " - remove the CSR resource"
  kubectl delete csr "${username}"

  echo "DEBUG (TODO: Must be removed):
Hashes (crt, key):"
  openssl x509 -in "${CRT_FILE}" -pubkey -noout | openssl sha256
  openssl rsa -in "${KEY_FILE}" -pubout -outform PEM | openssl sha256
  echo "-------------------------------"

  # Set credentials for user
  echo " - Set cert and key as credentials for user ${username}"
  echo "   kubectl config set-credentials ${username} \\
       --client-certificate=${CRT_FILE} \\
       --client-key=${KEY_FILE} \\
       --embed-certs=true"
  kubectl config set-credentials "${username}" \
    --client-certificate="${CRT_FILE}" \
    --client-key="${KEY_FILE}" \
    --embed-certs=true

  # add k8s context for user (this adds a context and a name to ~/.kube/config (or the file set by env var KUBECONFIG))
  echo " - Set context for user ${username}"
  echo "   kubectl config set-context ${username} \\
       --cluster=${K8S_CLUSTER} \\
       --user=${username}"
  kubectl config set-context "${username}" \
    --cluster="${K8S_CLUSTER}" \
    --user="${username}"

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

  echo "...done"
}



function sync_k8s_user() {
  local username="${1:-$ADMIN_USERNAME}"
  local k8s_cluster=${2:-$K8S_CLUSTER_KORIFI}
  local k8s_type=${3:-$K8S_TYPE}

  local k8s_prefix current_cluster

  case "${k8s_type^^}" in
    "KIND")	k8s_prefix="kind-" ;;
    "AKS")	k8s_prefix="" ;;
    "*")	echo "WARNING: No valid type provided ($k8s_type), using no prefix (valid: KIND, AKS)"
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
  local username=$1
  local cf_api_domain=${2:-$CF_API_DOMAIN}

  echo "Switch to user '$username'..."
  # Validate name in k8s
  echo " - validate username '$username' against k8s"
  assert kubectl config get-contexts | grep "$username" >/dev/null

  # Remark: Is it really required to switch context in k8s?!? If possible, remove it!!
  #         It is required to access the same K8s cluster with both cf and kubectl (if both are used),
  #         so therefore the switch will be made in K8s as well
  echo " - switch to k8s context ${username}"
  kubectl config use-context "${username}"

  echo " - setting cf api"
  cf api "https://$cf_api_domain" --skip-ssl-validation
  
  echo " - executing cf auth"
  echo "   cf auth '${username}'"
  cf auth "${username}"

  echo "...done"
}


function add_to_etc_hosts() {
  local add_string="$1"
  local search_string="$2"
  local before_or_after="${3:-AFTER}"

  #echo "DBG: add_to-etc_hosts('$1', '$2', '$3') - START"

  if [[ -z "$search_string" ]]; then
    # add a new line with the given add_string at the end of the file
    if ! grep "${add_string}" /etc/hosts >/dev/null; then
      echo "DBG: Adding as new line"
      echo "$add_string" | $SUDOCMD tee -a /etc/hosts > /dev/null
    else
      echo "DBG: Line already existing ($add_string)"
    fi
  else
    # add the add_string to the line(s) where the search_string is found,
    # before or after the search_string
    #echo "DBG: relevant line in /etc/hosts:"
    #grep "${search_string}" /etc/hosts
    #echo "---"
    if ! grep "${add_string}" /etc/hosts >/dev/null; then
      echo "DBG: Adding '$add_string' to above mentioned line"
      case "${before_or_after^^}" in
        "BEFORE") 
		echo "adding '$add_string' BEFORE '$search_string'"
		$SUDOCMD sed -i "s/$search_string/$add_string $search_string/" /etc/hosts
		;;
        "AFTER")
		echo "adding '$add_string' AFTER '$search_string'"
		$SUDOCMD sed -i "s/$search_string/$search_string $add_string/" /etc/hosts
		;;
	*) "WARNING: Invalid direction '$before_or_after'. No changes made!"
      esac
    else
      echo "WARNING: string '$add_string' already present, no need to add"
    fi
    #echo "DBG: Result:"
    #grep "${search_string}" /etc/hosts
    echo ""
  fi
}
