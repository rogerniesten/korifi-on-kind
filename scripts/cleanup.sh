#! /bin/bash
# shellcheck disable=SC2090     # it's a command, quoting will fail the command
##
## Cleanup to ensure a clean base before installing KinD (Kubernetes in Docker) and korifi
##

## Includes
. env/.env || { echo "Config ERROR! Script aborted"; exit 1; }                  # read paths from environment file
. "$LIB_PATH/cf_utils.sh"


##
## Config
##
export K8S_TYPE=KIND     					# type: KIND, AKS
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. "$ENV_PATH/.env.korifi" || { echo "Config ERROR! Script aborted"; exit 1; }   # read korifi config from environment file

read -r -p "Press enter to continue or CTRL-C to abort"

strongly_advice_root


##
## Cleanup
##
echo "cleanup..."
echo "DBG: $SUDOCMD kind delete clusters \"${K8S_CLUSTER_KORIFI}\""
$SUDOCMD kind delete clusters "${K8S_CLUSTER_KORIFI}"

$SUDOCMD kubectl config delete-user "cf-admin@${K8S_CLUSTER_KORIFI}"
$SUDOCMD kubectl config delete-context "cf-admin@${K8S_CLUSTER_KORIFI}"

rm ~/.cf -rf
rm ~/.kube/certs -rf
rm tmp -rf

echo "...done"
echo ""


