#! /bin/bash
##
## Library with several functions and utils for Korifi
##


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
  local csr_name="${username}@${K8S_CLUSTER}"
  local CERT_PATH="${CERT_PATH:-.}"
  local KEY_FILE="$CERT_PATH/${csr_name}.key"
  local CSR_FILE="$CERT_PATH/${csr_name}.csr"
  local CRT_FILE="$CERT_PATH/${csr_name}.crt"
  local csr_name="${username}@${K8S_CLUSTER}"

  echo "Create K8s user '$csr_name'..."
  # Create certificate for user
  echo " - Create certificate for user $csr_name"
  openssl genrsa -out "$KEY_FILE" 2048
  openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "/CN=${csr_name}"

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
  name: ${csr_name}
spec:
  request: ${csr_encoded}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${exp_period_in_sec}
  usages:
    - client auth
EOF

  # approve the signing request
  echo " - approve signing request"
  echo "   kubectl certificate approve ${csr_name}"
  kubectl certificate approve "$csr_name"

  echo " - retrieve the CRT"
  echo "   kubectl get csr ${csr_name} -o jsonpath='{.status.certificate}' | base64 -d > ${CRT_FILE}"
  kubectl get csr "${csr_name}" -o jsonpath='{.status.certificate}' | base64 -d > "${CRT_FILE}"

  # Set credentials for user
  echo " - Set cert and key as credentials for user ${csr_name}"
  kubectl config set-credentials "${csr_name}" \
    --client-certificate="${CRT_FILE}" \
    --client-key="${KEY_FILE}" \
    --embed-certs=true

  # add k8s context for user (this adds a context and a name to ~/.kube/config (or the file set by env var KUBECONFIG))
  echo " - Set context for user ${csr_name}"
  kubectl config set-context "${csr_name}" \
    --cluster="${K8S_CLUSTER}" \
    --user="${csr_name}"

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






function switch_user() {
  local username=$1

  echo "Switch to user '$username'..."
  # Validate name in k8s
  echo " - validate username '$username' against k8s"
  assert kubectl config get-contexts | grep "$username" >/dev/null

  # TODO: Is it really required to switch context in k8s?!? If possible, remove it!!
  echo " - switch to k8s context ${username}"
  kubectl config use-context "${username}"

#  echo " - setting cf api"
#  cf api https://localhost --skip-ssl-validation 
  echo " - executing cf auth"
  echo "   cf auth '${username}'"
  cf auth "${username}"

  echo "...done"
}

