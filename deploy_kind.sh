#! /bin/bash
# shellcheck disable=SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Installation a basic Kubernetes Cluster KinD (Kubernetes in Docker)
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
. .env || { echo "Config ERROR! Script aborted"; exit 1; }	# read config from environment file

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

install_if_missing apt curl
install_if_missing apt snap snapd
install_if_missing snap kubectl kubectl
install_if_missing apt docker docker.io "docker version"


## Install Go
if go version >/dev/null; then
  echo "✅ go (golang) is already installed."
else
  # based on: https://go.dev/doc/install
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
echo "TRC: $SUDOCMD kind create cluster --name ${K8S_CLUSTER_KORIFI} --config=${K8S_CLUSTER_KORIFI_YAML} --image kindest/node:v${K8S_VERSION}"
$SUDOCMD kind create cluster --name "${K8S_CLUSTER_KORIFI}" --config="${K8S_CLUSTER_KORIFI_YAML}" --image "kindest/node:v${K8S_VERSION}"
echo "verify result:"
assert "$SUDOCMD kind get clusters"
echo "...done"
echo ""

# Wait for the cluster to be ready
echo "Waiting for the K8s cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "...done"



echo ""
echo "======== Kind install finished ========"
echo ""
echo ""

