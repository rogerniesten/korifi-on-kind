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


install_go_if_missing "${GO_VERSION}"
install_kind_if_missing


##
## Create K8s cluster for korifi
##

# Now create a the Kubernetes cluster for Korifi
echo ""
echo "Creating K8s cluster '${K8S_CLUSTER_KORIFI}' using kind..."
echo "TRC: $SUDOCMD kind create cluster --name ${K8S_CLUSTER_KORIFI} --config=${K8S_CLUSTER_KORIFI_YAML} --image kindest/node:v${K8S_VERSION} --kubeconfig ~/.kube/config"
$SUDOCMD kind create cluster --name "${K8S_CLUSTER_KORIFI}" --config="${K8S_CLUSTER_KORIFI_YAML}" --image "kindest/node:v${K8S_VERSION}" --kubeconfig ~/.kube/config
echo "verify result:"
assert "$SUDOCMD kind get clusters"
echo "...done"
echo ""

# kubeconfig is written as root, make it readable to current user
sudo chown "${USER}:${USER}" -R ~/.kube

# Install Calico (for CNI Network Policy support)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# Wait for the cluster to be ready
echo "Waiting for the K8s cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "...done"

echo ""
echo "======== Kind install finished ========"
echo ""
echo ""

