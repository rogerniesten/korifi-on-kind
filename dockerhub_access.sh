#! /bin/bash
# shellcheck disable=SC2086,SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## This scripts disables/enables access to registry-1.docker.io by adding/removing an entry to /etc/hosts
## Purpose of disabling access to docker.io is to test installation of Korifi without need of external images

## Syntax: docker_access.sh <mode>
##
## Mode: on, enable, enabled
##	 off, disable, disabled

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/cf_utils.sh"


##
## Config
##
mode=${1^^}
docker_hub_domain=registry-1.docker.io

#. .env || { echo "Config ERROR! Script aborted"; exit 1; }      # read config from environment file

# Script should be executed as root (just sudo fails for some commands)
strongly_advice_root 1


case "$mode" in
  "ON"|"ENABLE"|"ENABLED")
	if grep "$docker_hub_domain" /etc/hosts >/dev/null; then
	  $SUDOCMD sed -i "/$docker_hub_domain/d" /etc/hosts
	  echo "Access to $docker_hub_domain restored."
	else
	  echo "$docker_hub_domain is already accessible, no changes made."
	fi
	;;
  "OFF"|"DISABLE"|"DISABLED")
	## Block access to hub.docker.io
	add_to_etc_hosts "127.0.0.1     $docker_hub_domain    # blocking access to $docker_hub_domain"
	echo "Access to $docker_hub_domain disabled."
	;;
  *)	echo "Invalid mode '$mode'. Valid modes are: ON, OFF, ENABLE, DISABLE"
	;;
esac

#
# End message
#
echo ""
echo "======== End of Script ========"
echo ""
echo ""

