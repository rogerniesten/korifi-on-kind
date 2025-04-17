#! /bin/bash
##
## Installation KinD (Kubernetes in Docker)
##



##
## Config
##
export k8s_cluster_korifi=korifi
export k8s_cluster_korifi_yaml="/tmp/k8s_korifi_cluster.yaml"
export GATEWAY_CLASS_NAME="contour"
GO_VERSION=1.24.2
GO_PACKAGE="go${GO_VERSION}.linux-amd64.tar.gz"

#echo " - container registry credentials"
#read -p "Username: " dockerhub_username
#read -s -p "Password: " dockerhub_password

#
# switch to sudo if not done yet
#
if [[ "$(id -u)" -eq 0 ]];then
  echo "Already running as root"
  SUDOCMD=""
else
  # let's check whether user can sudo (and cache the password for further sudo commands in the script)
  echo "Enter sudo password to check sudo permissions"
  sudo echo "sudo ok"
  echo "Running as '$(whoami)', but capable of sudo to root"
  SUDOCMD='sudo env "PATH=$PATH"'

  echo "Recommended is to run as root (sudo $). Running as $(whoami) has turned out to cause issues."
  echo "Press enter to continue or CTRL-C to exit"
  read
fi



##
## Functions
##
function cleanup_file() {
  filename="$1"
  if [[ -f "$filename" ]]; then
    $SUDOCMD rm -rf "$filename"
    rv=$?
    if [[ $rv -ne 0 ]]; then
      exit $rv
    fi
  fi
}


function assert() {
  $@
  result=$?
  if [[ "$result" -eq "0" ]] ; then
    echo "Command '$*' succeeded"
  else
    echo "Command '$*' FAILED!"
    exit $result
  fi
}



##
## Cleanup
##
echo "cleanup..."
#if $($SUDOCMD kind get clusters | grep 'korifi'); then
  $SUDOCMD kind delete clusters ${k8s_cluster_korifi}
#fi
rm ~/.cf -rf

cleanup_file "./k8s_korifi_cluster.yaml"
cleanup_file "./contour.gatewayclass.yaml"
cleanup_file "./contour.gateway.yaml"
cleanup_file "./namespaces.yaml"
cleanup_file "/usr/share/keyrings/cli.cloudfoundry.org.gpg"
cleanup_file "/etc/apt/sources.list.d/cloudfoundry-cli.list"
echo "...done"

## Installation on Ubuntu 20.04 LTS VM (as test to install it on Synology NAS)
# korifi1.ronits.local
# 192.168.0.156

##
## Installing required tools
##

echo ""
echo ""
echo "Installing required tools"
echo "-------------------------"
echo ""


## Install jq
$SUDOCMD apt install -y jq
#verify
assert jq --version

## Install Go
echo "Installing Go..."
#$SUDOCMD apt install golang-go
# This command install go version 1.18.0
# The makefile of dorifi (in the github korifi repository) requires a newer version
# (minimal GO 1.20 due to the -C flag for the go build command).
# Therefore the option mentioned in go.dev is used:
# source: https://go.dev/doc/install
wget https://go.dev/dl/${GO_PACKAGE} -O /tmp/${GO_PACKAGE}
$SUDOCMD rm -rf /usr/local/go && $SUDOCMD tar -C /usr/local -xzf /tmp/${GO_PACKAGE}
export PATH=$PATH:/usr/local/go/bin                                     # add go/bin folder to PATH
echo "export PATH=$PATH:/usr/local/go/bin" >/etc/profile.d/go.sh        # and make it persistent
echo "verify result:"
assert "go version"
# expected: version info of go
echo "...done"
echo ""


## Install goalngci-lint
#Not required at this moment
#curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s v2.0.2




## Install docker
echo "Installing docker (if not installed yet)..."
$SUDOCMD apt install docker.io
echo "...done"
echo ""



## Install KinD
# For AMD64 / x86_64
echo "Installing kind (Kubernetes in Docker)..."
[ $(uname -m) = x86_64 ] && curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
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
#verify
echo "verify result:"
assert which kubectl
# expected: /snap/bin/kubectl
kubectl version
# not using assert as there is no k8s cluster yet to communicate with which results in a error
# expected: help of kubectl (a lot of info with all sub commands, etc)
echo "...done"
echo ""


## Install helm

echo "Install helm (if required)..."
# Add the Helm GPG key
curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/helm.gpg > /dev/null
# Install apt-transport-https if not already installed
$SUDOCMD apt install -y apt-transport-https
# Add the Helm repository
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
# Update package list and Install Helm
$SUDOCMD apt update
$SUDOCMD apt install -y helm
#verify
echo "verify result:"
assert helm version
# expected:
#       version.BuildInfo{Version:"v3.17.2", GitCommit:"cc0bbbd6d6276b83880042c1ecb34087e84d41eb", GitTreeState:"clean", GoVersion:"go1.23.7"}
echo "...done"
echo ""



## Install cf (cloudfoundry command)

#source: https://docs.cloudfoundry.org/cf-cli/install-go-cli.html
echo "Install cf (cloud foundry command)..."
# add cloudfoundry foundation pyblic key and package repository to your system
curl -fsSL https://packages.cloudfoundry.org/debian/cli.cloudfoundry.org.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/cloudfoundry.org.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudfoundry.org.gpg] https://packages.cloudfoundry.org/debian stable main" | sudo tee /etc/apt/sources.list.d/cloudfoundry-cli.list
# update local package index
$SUDOCMD apt update
# install cf (v7 or v8)
#sudo apt install cf7-cli
$SUDOCMD apt install -y cf8-cli

# above fails (for both version) on SynoNAS VM, below works fine, but fails on Azure VM
#wget -O - https://packages.cloudfoundry.org/stable?release=debian64&version=v8&source=github cf8-cli.deb
#sudo dpkg -i cf8-cli.deb
echo "verify:"
assert cf --version
#expected:
#       help of cf command
echo "...done"



## OPTIONAL! Installing kube-state-metrics
## sources:
## - https://www.linkedin.com/learning/kubernetes-package-management-with-helm-2020/install-a-helm-chart-in-your-kubernetes-cluster?autoSkip=true&resume=false
## - https://artifacthub.io/packages/helm/bitnami/kube-state-metrics
# echo "Install kube-state-metrics..."
# $SUDOCMD kubectl create ns metrics
# old way of working, for CI/CD use OCI
# $SUDOCMD helm repo add bitnami https://charts.bitnami.com/bitnami
# helm install kube-state-metrics bitnami/kube-state-metrics -n metrics
# new way of working with OCI
# helm install kube-state-metrics oci://registry-1.docker.io/bitnamicharts/metrics-server
# verify
# echo "verify result:"
# expected:
# echo "...done"
# echo ""




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







##
## Create K8s cluster for korifi
##

# Now create a the korifi cluster
echo ""
echo "Creating K8s cluster '${k8s_cluster_korifi}' using kind..."
# remove cluster with: sudo kind delete cluster ${k8s_cluster_korifi}
# prepare yaml file
echo "storing kind config for korifi cluster to '${k8s_cluster_korifi_yaml}'"
cat <<EOF >${k8s_cluster_korifi_yaml}
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localregistry-docker-registry.default.svc.cluster.local:30050"]
        endpoint = ["http://127.0.0.1:30050"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs]
      [plugins."io.containerd.grpc.v1.cri".registry.configs."127.0.0.1:30050".tls]
        insecure_skip_verify = true
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 32080
    hostPort: 80
    protocol: TCP
  - containerPort: 32443
    hostPort: 443
    protocol: TCP
  - containerPort: 30050
    hostPort: 30050
    protocol: TCP
EOF

#> sudo kind create cluster --name ${k8s_cluster_korifi} --config=${k8s_cluster_korifi_yaml}
$SUDOCMD kind create cluster --name ${k8s_cluster_korifi} --config=${k8s_cluster_korifi_yaml} --image kindest/node:v1.30.0


echo "verify result:"
assert $SUDOCMD kind get clusters
echo "...done"
echo ""

# cluster can be removed by
# $ sudo kind delete cluster <name>
# please that all actions below need to be redone


echo "Switching to k8s cluster '${k8s_cluster_korifi}'..."
$SUDOCMD kubectl config use-context kind-${k8s_cluster_korifi}
echo "verify result:"
assert $SUDOCMD kubectl config get-contexts
# expected: asterix before 'korifi'
echo "...done"
echo ""





##
## Now install Korifi
##

# source: https://github.com/cloudfoundry/korifi/blob/main/INSTALL.kind.md


echo ""
echo ""
echo "Installing Korifi"
echo "-----------------"
echo ""
echo "to see logs, use: $SUDOCMD kubectl -n korifi-installer logs --follow job/install-korifi"

# run the installer job
echo " - run installer job"
$SUDOCMD kubectl apply -f https://github.com/cloudfoundry/korifi/releases/latest/download/install-korifi-kind.yaml

# Wait for the deployments in the korifi namespace to be available
#echo "   waiting for deployments to become available..."
#$SUDOCMD kubectl wait --for=condition=available --timeout=300s deployment --all -n korifi
#echo "   ...done"


# Wait until korifi pods are visible with kubectl get pods -n korifi
echo -n "Waiting for korifi pods to be created."
while [ "$(kubectl get pods -n korifi 2>/dev/null | grep '^korifi' | wc -l)" -eq 0 ]; do
  sleep 1
  echo -n "."
done
echo ""

# Wait for all pods in the korifi namespace to be ready
echo "Waiting for all pods in the 'korifi' namespace to be ready..."
$SUDOCMD kubectl wait --for=condition=Ready pods --all --namespace korifi --timeout=300s
echo "All pods are ready. Proceeding with next steps..."

# wait another minute to be sure
echo -n "waiting another minute to be sure."
for (( i=0; i<60; i++));do
  echo -n "."
  sleep 1
done
echo ""

# Set api and login
cf version
cf api https://localhost --skip-ssl-validation
cf login -u kind-korifi

#cf auth d-korifi
#cf login --skip-ssl-validation

cf create-org org
cf create-space -o org space
cf target -o org -s space







## Create a Kubernetes service account
# TODO: Check whether this account is still required!
# PRE K8s v1.24:
if [[ ! $(kubectl get sa korifi-user 2>/dev/null) ]];then
  echo "Create korifi-user..."
  kubectl create sa korifi-user -n default
fi

if [[ ! $(kubectl get clusterrolebinding korifi-user-bindingi 2>/dev/null) ]];then
  echo "Creating clusterrolebinding for korifi-user..."
  kubectl create clusterrolebinding korifi-user-binding \
    --clusterrole=cluster-admin \
    --serviceaccount=default:korifi-user
fi

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: korifi-user-token
  annotations:
    kubernetes.io/service-account.name: korifi-user
type: kubernetes.io/service-account-token
EOF





#
# End message
#
echo ""
echo "Korifi install finished"
echo ""
echo ""

exit 0















# wait a few seconds
sleep 5

# Get the token
SA_TOKEN=$(kubectl get secret korifi-user-token -n default -o jsonpath='{.data.token}' | base64 --decode)
# get the CA cert (optional)
SA_CACERT=$(kubectl get secret korifi-user-token -n default -o jsonpath='{}' | jq -r '.data["ca.crt"]' | base64 --decode)



# Create an entry in the kubeconfig
kubectl config set-credentials korifi-user --token=$SA_TOKEN
#kubectl config set-cluster korifi-cluster --server=https://localhost --certificate-authority=korifi-ca.crt
#kubectl config set-cluster korifi-cluster --server=https://localhost --insecure-skip-tls-verify=true
kubectl config set-cluster kind-korifi --server=https://localhost:43359 --insecure-skip-tls-verify=true
kubectl config set-context korifi-context --cluster=kind-korifi --user=korifi-user
kubectl config use-context korifi-context




##
## Login to korifi
##

cf api https://localhost --skip-ssl-validation

cf auth d-korifi

cf login --skip-ssl-validation



cf create-org org
cf create-space -o org space
cf target -o org -s space

