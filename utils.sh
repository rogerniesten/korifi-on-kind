#! /bin/bash
##
## Library with several functions and utils
##



#
# switch to sudo if not done yet
#
strongly_advice_root() {

  if [[ "$(id -u)" -eq 0 ]];then
    echo "Running as root, so all fine."
    export SUDOCMD=""
  else
    # let's check whether user can sudo (and cache the password for further sudo commands in the script)
    echo "Enter sudo password to check sudo permissions"
    sudo echo "sudo ok"
    echo "Running as '$(whoami)', but capable of sudo to root"
    export SUDOCMD='sudo env "PATH=$PATH"'
  
    echo "Recommended is to run as root (sudo $). Running as $(whoami) has turned out to cause issues in some cases."
    echo "Press enter to continue or CTRL-C to exit"
    read
  fi
}



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


