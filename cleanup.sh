#! /bin/bash
##
## Cleanup to ensure a clean base before installing KinD (Kubernetes in Docker) and korifi
##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"



##
## Config
##
export k8s_cluster_korifi=korifi


strongly_advice_root


##
## Cleanup
##
echo "cleanup..."
#if $($SUDOCMD kind get clusters | grep 'korifi'); then
# shellcheck disable=SC2090	# it's a command, quoting will fail the command
$SUDOCMD kind delete clusters "${k8s_cluster_korifi}"
#fi
rm ~/.cf -rf
rm ~/.kube/certs -rf
rm tmp -rf

cleanup_file "/usr/share/keyrings/cli.cloudfoundry.org.gpg"
cleanup_file "/etc/apt/sources.list.d/cloudfoundry-cli.list"
echo "...done"
echo ""


