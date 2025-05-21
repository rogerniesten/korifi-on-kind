#! /bin/bash
##
## Library with several functions and utils for Korifi
##
#set -euo pipefail

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"



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
  cf api "https://$CF_API_DOMAIN" --skip-ssl-validation
  
  echo " - executing cf auth"
  echo "   cf auth '${username}'"
  cf auth "${username}"

  echo "...done"
}

