#! /bin/bash
# shellcheck disable=SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Installation a basic Kubernetes Cluster KinD (Kubernetes in Docker)
##

## Includes
. env/.env || { echo "Config ERROR! Script aborted"; exit 1; }                  # read paths from environment file
. "$LIB_PATH/cf_utils.sh"


##
## Script argument parsing and syntax message
##

function syntax(){
  local msg="${1:-}"
  local rv=0

  if [[ -n "$msg" ]]; then
    echo -e "\n$msg"
    rv=1
  fi
  echo "
Install a KIND (Kubernetes IN Docker) Cluster.

Syntax:

  $0 [-C|--cluster-name <name>] $(logging__get_args) [-h|--help]

Parameters:
  -C|--cluster-name; Name of the K8s cluster to be used/created for Korifi. This arg overrules
                     environment variable K8S_CLUSTER_KORIFI
  -h|--help;         Show this syntax info
$(logging__show_args_desc)
"
  exit "$rv"
}

log "$LOG_TR5" "*** Parsing args in $0 ($*)"
while [[ $# -gt 0 ]]; do

  # Pas current arg to logging library if it wants to process it
  if logging__parse_arg "$@"; then
    shift $__LOGGING__ARGS_CONSUMED     # logging__parse_args tells us how many args to consume
    continue
  fi

  # Parse script specific args
  case "$1" in
    -h|--help)          syntax ;;
    -C|--cluster-name)  K8S_CLUSTER_KORIFI="$2";        log "$LOG_TR5" "handled -C $2"; shift 2 ;;
    --)                 break;                          log "$LOG_TR5" "stop parsing";  shift ;;
    *)  syntax "ERROR: Invalid arg $1" ;;
  esac
done



##
## Config
##
export K8S_TYPE=KIND                                                            # type: KIND, AKS
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. "$ENV_PATH/.env_korifi" || { echo "Config ERROR! Script aborted"; exit 1; }   # read korifi config from environment file

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
install_if_missing snap go go "go version"
install_if_missing apt docker docker.io "docker version"

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

