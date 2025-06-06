#! /bin/bash
# shellcheck disable=SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Installation a basic Korifi Cluster KinD (Kubernetes in Docker)
##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/cf_utils.sh"
tmp="$scriptpath/tmp"
mkdir -p "$tmp"



##
## Config
##
export K8S_TYPE=KIND     					# type: KIND, AKS
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. .env || { echo "Config ERROR! Script aborted"; exit 1; }      # read config from environment file

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

## GPG keys and repo sources are added in .env file

install_if_missing apt jq jq "jq --version"
install_if_missing apt curl
install_if_missing apt helm helm "helm version"
install_if_missing apt cf cf8-cli

install_if_missing apt snap snapd
install_if_missing snap yq yq "yq --version"
install_if_missing snap kubectl kubectl

# required for KIND
install_if_missing apt docker docker.io "docker version"

install_go_if_missing "${GO_VERSION}"
install_kind_if_missing



##
## Create K8s cluster for korifi
##

# Now create a the Kubernetes cluster for Korifi
echo ""
echo "Creating K8s cluster '${K8S_CLUSTER_KORIFI}' using kind..."
$SUDOCMD kind create cluster --name "${K8S_CLUSTER_KORIFI}" --config="${K8S_CLUSTER_KORIFI_YAML}" --image "kindest/node:v${K8S_VERSION}"
echo "verify result:"
assert "$SUDOCMD kind get clusters"
echo "...done"
echo ""

# Wait for the cluster to be ready
echo "Waiting for the K8s cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "...done"


# TODO: Workaround for kpack installation
#	kpack installation might fail because some CRD's are not installed in time
#	By installing only the CRD parts of kpack first, this issue is bypassed
#	Therefore kpack is already installed now.
install_kpack "$KPACK_VERSION"


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
echo "   TRC: $SUDOCMD kubectl apply -f https://github.com/cloudfoundry/korifi/releases/latest/download/install-korifi-kind.yaml"
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


echo "Creating admin user '$ADMIN_USERNAME'"

## Create certificates for cf-admin
echo "Create certificates for '$ADMIN_USERNAME'"
create_k8s_user_cert "$ADMIN_USERNAME"

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



##
## Login to Korifi as admin and show some demoe results
##

echo "cf api https://${CF_API_DOMAIN} --skip-ssl-validation"
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
echo "cf login -u ${ADMIN_USERNAME} -a https://${CF_API_DOMAIN} --skip-ssl-validation"
cf login -u "${ADMIN_USERNAME}" -a "https://${CF_API_DOMAIN}" --skip-ssl-validation


# create a default org and default space
echo "cf create-org org"
cf create-org org
echo "cf create-space -o org space"
cf create-space -o org space
echo "cf target -o org -s space"
cf target -o org -s space



#
# End message
#
echo ""
echo "======== Korifi install finished ========"
echo ""
echo ""

