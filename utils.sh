#! /bin/bash
##
## Library with several functions and utils
##



SUDOCMD=""	# default value

#
# switch to sudo if not done yet
#
strongly_advice_root() {
  local timeout=${1:-10}

  if [[ "$(id -u)" -eq 0 ]];then
    echo "Running as root, so all fine."
    export SUDOCMD=""
  else
    # let's check whether user can sudo (and cache the password for further sudo commands in the script)
    echo "Enter sudo password to check sudo permissions"
    sudo echo "sudo ok"
    echo "Running as '$(whoami)', but capable of sudo to root"
    # shellcheck disable=SC2016,SC2089	# this is meant to be litterall!
    export SUDOCMD='sudo env "PATH=$PATH"'
  
    echo "Recommended is to run as root (sudo $). Running as non-root user like '$(whoami)' might cause issues."
    echo "Press enter to continue or CTRL-C to exit"
    echo "Script will continue automatically in $timeout seconds."
    read -r -t "$timeout"
  fi
}




##
## Functions
##
function cleanup_file() {
  filename="$1"
  if [[ -f "$filename" ]]; then
    # shellcheck disable=SC2090		# this is meant to be a command, so quoting would have wrong effect
    $SUDOCMD rm -rf "$filename"
    rv=$?
    if [[ $rv -ne 0 ]]; then
      exit $rv
    fi
  fi
}


function trim() {
  local var="$*"
  # Remove leading whitespace
  var="${var#"${var%%[![:space:]]*}"}"
  # Remove trailing whitespace
  var="${var%"${var##*[![:space:]]}"}"
  echo "$var"
}


function assert() {
  bash -c "$*"
  result=$?
  if [[ "$result" -eq "0" ]] ; then
    echo "Command '$*' succeeded"
  else
    echo "Command '$*' FAILED!"
    exit $result
  fi
}


function validate_guid() {
  local guid="$1"
  if [[ "$guid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
    #echo "DBG: '$guid' valid GUID"
    return 0
  else
    #echo "DBG: '$guid' is invalid GUID"
    return 1
  fi
}

function validate_not_empty() {
  local value="$1"
  if [[ -n "$value" ]]; then
    #echo "DBG: var is NOT empty"
    return 0
  else
    #echo "DBG: var is empty"
    return 1
  fi
}

function validate_dummy() {
  # dummy validation that always returns true
  return 0
}


function prompt_if_missing() {
  #echo "DBG: prompt_if_missing( varname='$1', vartyp='${2^^}', prompt='$3', env_file='$4', validate_fn='$validate_fn') - START"
  local var_name="$1"
  local var_type="${2^^:-VAR}"     #var, secret
  local prompt_text="${3:-Enter value for variable $var_name}"
  local env_file="${4:-}"
  local validate_fn=${5:-validate_not_empty}

  local current_value="${!var_name}"
  local read_params=""
  if [[ "${var_type^^}" == "SECRET" ]]; then read_params="-s "; fi

  #echo "DBG: current value for var $var_name is '$current_value'."
  # Prompt once if value is missing
  if [[ -z "$current_value" ]]; then
    # shellcheck disable=SC2229,SC2086
    read -r $read_params -p "$prompt_text: " current_value
    [[ "$var_type" == "SECRET" ]] && echo ""
  fi

  # Validate if needed (loop until valid)
  while ! $validate_fn "$current_value"; do
    # shellcheck disable=SC2229,SC2086
    read -r $read_params -p "$prompt_text: " current_value
    if [[ "${var_type^^}" == "SECRET" ]]; then echo ""; fi	# add linefeed after secret input
  done

  export "$var_name"="$current_value"

  # Save to env-file
  if [[ "${var_type^^}" != "SECRET" && -n "${env_file:-}" ]]; then
    if grep -q "^export $var_name=" "$env_file" 2>/dev/null; then
      sed -i "s|^export $var_name=.*|export $var_name=\"$current_value\"|" "$env_file"
    else
      echo "export $var_name=\"$current_value\"" >> "$env_file"
    fi
  fi
}


function install_if_missing() {
  local installer tool package verify_cmd
  installer="${1:-}"		# installer: apt, dnf, yum, packman, snap, brew (auto means, let the function figure out...)
  tool="$2"			# name of the tool (or keyword 'package' in case of a command-less package)
  package="${3:-$tool}"		# package to be installed 
  verify_cmd=$(trim "${4:-}")	# optional

  hash -r  # Clear cached command locations

  # Check package by installer if no binary or force set
  local installed=false
  if [[ "${tool^^}" == "PACKAGE" ]]; then
    case "$installer" in
      apt)	dpkg -s "$package" &>/dev/null && installed=true ;;
      dnf|yum)	rpm -q "$package" &>/dev/null && installed=true ;;
      pacman)	pacman -Qi "$package" &>/dev/null && installed=true ;;
      snap)	snap list | grep -q "^$package " && installed=true ;;
      brew)	brew list --formula | grep -qx "$package" && installed=true ;;
      auto)	echo "" ;; # No check implemented, just installed 
      *)        echo "❌ Unsupported installer: $installer"; return 1 ;;
    esac
  else
   if command -v "$tool" >/dev/null 2>&1; then

    installed=true
   fi
  fi

  if $installed; then
    echo "✅ $tool ($package) is already installed."
    return 0
  fi

  echo "🔍 $tool ($tool) not found. Attempting to install ${package}..."

  case "$installer" in
    apt)	sudo apt update && sudo apt install -y "$package" ;;
    apt-get)	sudo apt-get update && sudo apt-get install -y "$package" ;;
    snap)	sudo snap install "$package" 
	    	result=$?
		if [[ "$result" -eq "1" ]]; then
		  echo "retry with --classic..."
		  sudo snap install "$package" --classic
		fi
		;;
    dnf) 	sudo dnf install -y "$package" ;;
    yum)	sudo yum install -y "$package" ;;
    pacman)	sudo pacman -Sy --noconfirm "$package" ;;
    brew)	brew install "$package" ;;
    auto)	# Auto-detect installer
		if command -v apt-get >/dev/null 2>&1; then
		  sudo apt-get update && sudo apt-get install -y "$package"
                elif command -v snap >/dev/null 2>&1; then
                  sudo snap install "$package"
		elif command -v dnf >/dev/null 2>&1; then
		  sudo dnf install -y "$package"
		elif command -v yum >/dev/null 2>&1; then
		  sudo yum install -y "$package"
		elif command -v pacman >/dev/null 2>&1; then
		  sudo pacman -Sy --noconfirm "$package"
		elif command -v brew >/dev/null 2>&1; then
		  brew install "$package"
		else
		  echo "❌ Could not find a supported package manager to install $tool."
		  return 1
		fi
		;;
      *)	echo "❌ Unsupported installer: $installer"; return 1 ;;
  esac

  if [[ -n "$verify_cmd" ]]; then
    echo "Verify ($verify_cmd):"
    assert "$verify_cmd"
  fi

  if command -v "$tool" >/dev/null 2>&1; then
    echo "✅ Successfully installed $tool."
    return 0
  else
    echo "❌ Failed to install $tool."
    return 1
  fi
}


function install_go_if_missing() {

  #install_if_missing apt go golang-go "go version"
  #return $?

  # Version 1.21+ is required, but apt installs 1.18 (21-05-2025).
  # Now using snap which installs version 1.24
  install_if_missing snap go go "go version"
  return $?
}


function install_kind_if_missing() {

  if [[ -f "/usr/local/bin/kind" ]]; then
    echo "✅ kind (Kubernetes in Docker) is already installed."
    return 0
  fi

  ## Install KinD
  # For AMD64 / x86_64
  echo "Installing kind (Kubernetes in Docker)..."
  [ "$(uname -m)" = "x86_64" ] && curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
  echo "...done"
  echo ""
}



function duration2sec() {
  local input="${1// /}"  # remove all spaces
  local total=0
  local rest="$input"
  local matched number unit

  while [[ $rest =~ ^([0-9]+)([a-z]*) ]]; do
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    matched="${BASH_REMATCH[0]}"

    # Only accept lowercase units, default to seconds if no unit
    case "$unit" in
      "")  (( total += number )) ;;
      s)   (( total += number )) ;;
      m)   (( total += number * 60 )) ;;
      h)   (( total += number * 3600 )) ;;
      d)   (( total += number * 86400 )) ;;
      w)   (( total += number * 604800 )) ;;
      ms)  (( total += number / 1000 )) ;;
      us)  (( total += number / 1000000 )) ;;
      *)
          echo "Error: unknown or invalid unit '$unit'" >&2
          return 1
          ;;
    esac

    rest="${rest#"$matched"}"
  done

  if [[ -n $rest ]]; then
    echo "Error: leftover unparsed input: '$rest'" >&2
    return 1
  fi

  echo "$total"
}

