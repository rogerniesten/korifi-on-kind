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

## First add GPG keys and repo sources

# Helm
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

# required for KIND
install_if_missing apt docker docker.io "docker version"


## Install Go
if go version >/dev/null; then
  echo "✅ go (golang) is already installed."
else
  # based on: https://go.dev/doc/install
  echo "Installing Go..."
  wget https://go.dev/dl/${GO_PACKAGE} -O "$tmp/${GO_PACKAGE}"
  tar -C /usr/local -xzf "$tmp/${GO_PACKAGE}"
  export PATH=$PATH:/usr/local/go/bin                                     # add go/bin folder to PATH
  echo "export PATH=$PATH:/usr/local/go/bin" >/etc/profile.d/go.sh        # and make it persistent
  echo "verify result:"
  assert "go version"
  # expected: version info of go
  echo "...done"
  echo ""
fi


## Install KinD
# For AMD64 / x86_64
if kind version >/dev/null; then
  echo "✅ kind (Kubernetes IN Docker) is already installed."
else
  echo "Installing kind (Kubernetes in Docker)..."
  [ "$(uname -m)" = "x86_64" ] && curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
  chmod +x ./kind
  $SUDOCMD mv ./kind /usr/local/bin/kind
  echo "...done"
  echo ""
fi


##
## Create K8s cluster for korifi
##

# Now create a the Kubernetes cluster for Korifi
echo ""
echo "Creating K8s cluster '${K8S_CLUSTER_KORIFI}' using kind..."
$SUDOCMD kind create cluster --name ${K8S_CLUSTER_KORIFI} --config="${K8S_CLUSTER_KORIFI_YAML}" --image "kindest/node:v${K8S_VERSION}"
echo "verify result:"
assert "$SUDOCMD kind get clusters"
echo "...done"
echo ""

# Wait for the cluster to be ready
echo "Waiting for the K8s cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "...done"



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

echo "cf api ${CF_API_DOMAIN} --skip-ssl-validation"
cf api "${CF_API_DOMAIN}" --skip-ssl-validation
echo "cf login -u ${ADMIN_USERNAME} -a ${CF_API_DOMAIN} --skip-ssl-validation"
cf login -u "${ADMIN_USERNAME}" -a "${CF_API_DOMAIN}" --skip-ssl-validation


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

