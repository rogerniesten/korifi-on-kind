#! /bin/bash
# shellcheck disable=SC2090     # it's a command, quoting will fail the command
##
## Cleanup to ensure a clean base before installing KinD (Kubernetes in Docker) and korifi
##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"


##
## Config
##
export K8S_TYPE=KIND     					# type: KIND, AKS
prompt_if_missing K8S_TYPE "var" "Which K8S type to use? (KIND, AKS)"
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. .env || { echo "Config ERROR! Script aborted"; exit 1; }	# read config from environment file
read -p "Press enter to continue or CTRL-C to abort"

strongly_advice_root


##
## Cleanup
##
echo "cleanup..."
#if $($SUDOCMD kind get clusters | grep 'korifi'); then
echo "DBG: $SUDOCMD kind delete clusters \"${K8S_CLUSTER_KORIFI}\""
$SUDOCMD kind delete clusters "${K8S_CLUSTER_KORIFI}"

$SUDOCMD kubectl config delete-user "cf-admin@${K8S_CLUSTER_KORIFI}"
$SUDOCMD kubectl config delete-context "cf-admin@${K8S_CLUSTER_KORIFI}"

#fi
rm ~/.cf -rf
rm ~/.kube/certs -rf
rm tmp -rf

cleanup_file "/usr/share/keyrings/cli.cloudfoundry.org.gpg"
cleanup_file "/etc/apt/sources.list.d/cloudfoundry-cli.list"
echo "...done"
echo ""


