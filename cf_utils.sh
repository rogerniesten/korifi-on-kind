#! /bin/bash
##
## Library with several functions and utils for Korifi
##


function switch_user() {
  local username=$1

  echo "Switch to user '$username'..."
  # Validate name in k8s
  echo " - validate username '$username' against k8s"
  assert kubectl config get-contexts | grep "$username" >/dev/null

  echo " - switch to k8s context ${username}"
  kubectl config use-context "${username}"

#  echo " - setting cf api"
#  cf api https://localhost --skip-ssl-validation 
  echo " - executing cf auth"
  echo "   cf auth '${username}'"
  cf auth "${username}"

  echo "...done"
}

