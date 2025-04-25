#! /bin/bash
##
## Installation a basic Korifi Cluster KinD (Kubernetes in Docker)
##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"
tmp="$scriptpath/tmp"
mkdir -p "$tmp"



##
## Config
##
export k8s_cluster_korifi=korifi
export k8s_cluster_korifi_yaml="${scriptpath}/k8s_korifi_cluster_config.yaml"
export GATEWAY_CLASS_NAME="contour"
GO_VERSION=1.24.2
GO_PACKAGE="go${GO_VERSION}.linux-amd64.tar.gz"


strongly_advice_root



##
## Installing required tools
##

echo ""
echo ""
echo "Installing required tools"
echo "-------------------------"
echo ""

$SUDOCMD apt install -y jq docker.io curl

#verify required tools
assert jq --version


## Install Go
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


## Install KinD
# For AMD64 / x86_64
echo "Installing kind (Kubernetes in Docker)..."
[ "$(uname -m)" = "x86_64" ] && curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
chmod +x ./kind
$SUDOCMD mv ./kind /usr/local/bin/kind
echo "...done"
echo ""


## Install kubectl
# $SUDOCMD snap install kubectl
# error: This revision of snap "kubectl" was published using classic confinement and thus may perform
#        arbitrary system changes outside of the security sandbox that snaps are usually confined to,
#        which may put your system at risk.
#
#        If you understand and want to proceed repeat the command including --classic.
echo "Install kubectl (if required)..."
$SUDOCMD snap install kubectl --classic
echo "verify result:"
assert which kubectl
# expected: /snap/bin/kubectl
echo "...done"
echo ""


## Install helm
echo "Install helm (if required)..."
curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/helm.gpg > /dev/null	# Add the Helm GPG key
$SUDOCMD apt install -y apt-transport-https										# install dependencies for helm
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list	# Add reqruied repo source for helm
$SUDOCMD apt update && $SUDOCMD apt install -y helm									# Update package list and Install Helm
#verify
echo "verify result:"
assert helm version
# expected: version.BuildInfo{Version:"v3.17.2", GitCommit:"cc0bbbd6d6276b83880042c1ecb34087e84d41eb", GitTreeState:"clean", GoVersion:"go1.23.7"}
echo "...done"
echo ""


## Install cf (cloudfoundry CLI)
# based on: https://docs.cloudfoundry.org/cf-cli/install-go-cli.html
echo "Install cf (cloud foundry command)..."
# add cloudfoundry foundation pyblic key and package repository to your system
curl -fsSL https://packages.cloudfoundry.org/debian/cli.cloudfoundry.org.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/cloudfoundry.org.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudfoundry.org.gpg] https://packages.cloudfoundry.org/debian stable main" | sudo tee /etc/apt/sources.list.d/cloudfoundry-cli.list
$SUDOCMD apt update && $SUDOCMD apt install -y cf8-cli	# Update package list and Install cf8-cli
# Note: above fails (for both version) on SynoNAS VM, below works fine, but fails on Azure VM
#	wget -O - https://packages.cloudfoundry.org/stable?release=debian64&version=v8&source=github cf8-cli.deb
#	sudo dpkg -i cf8-cli.deb
echo "verify:"
assert cf --version
#expected: help of cf command
echo "...done"


##
## Some patches / workarounds 
##

## Issue: 
## helm dependency build
## no repository definition for https://kubernetes-charts.storage.googleapis.com/
##
## Explanation:
## This URL is deprecated — it was the default Helm stable chart repo used in Helm v2, but it’s been shut down.
##
## Fix:
## Add the new location for the stable repo manually:
helm repo add stable https://charts.helm.sh/stable
helm repo update

#
# Patching deployment to add args for tls (ChatGPT suggestion):
#
#echo "Patching deployment to add args for tls..."
#$SUDOCMD kubectl patch deployment korifi-api-deployment -n korifi \
#  --type='json' \
#  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args", "value": [
#    "--tls-cert-file=/etc/korifi-tls-config/tls.crt",
#    "--tls-key-file=/etc/korifi-tls-config/tls.key",
#    "--client-ca-file=/etc/korifi-tls-config/ca.crt"
#  ]}]'
#
## wait for the deployment to be finsihed
#kubectl wait deployment korifi-api-deployment \
#  --namespace korifi \
#  --for=condition=Available \
#  --timeout=60s
#
## verify
#korifi_api_patch=$?
#assert test $korifi_api_patch




##
## Create K8s cluster for korifi
##

# Now create a the korifi cluster
echo ""
echo "Creating K8s cluster '${k8s_cluster_korifi}' using kind..."
$SUDOCMD kind create cluster --name ${k8s_cluster_korifi} --config="${k8s_cluster_korifi_yaml}" --image kindest/node:v1.30.0

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



##
## Login to Korifi as admin and show some demoe results
##

cf api https://localhost --skip-ssl-validation
cf login -u kind-korifi

# create a default org and default space
cf create-org org
cf create-space -o org space
cf target -o org -s space





## Create a Kubernetes service account
# TODO: Check whether this account is still required!
# PRE K8s v1.24:
#if [[ ! $(kubectl get sa korifi-user 2>/dev/null) ]];then
#  echo "Create korifi-user..."
#  kubectl create sa korifi-user -n default
#fi
#
#if [[ ! $(kubectl get clusterrolebinding korifi-user-bindingi 2>/dev/null) ]];then
#  echo "Creating clusterrolebinding for korifi-user..."
#  kubectl create clusterrolebinding korifi-user-binding \
#    --clusterrole=cluster-admin \
#    --serviceaccount=default:korifi-user
#fi
#
#kubectl apply -f - <<EOF
#apiVersion: v1
#kind: Secret
#metadata:
#  name: korifi-user-token
#  annotations:
#    kubernetes.io/service-account.name: korifi-user
#type: kubernetes.io/service-account-token
#EOF





#
# End message
#
echo ""
echo "======== Korifi install finished ========"
echo ""
echo ""

