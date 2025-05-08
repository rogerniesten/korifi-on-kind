#! /bin/bash
##
## Library with several functions and utils
##



SUDOCMD=""	# default value

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
    # shellcheck disable=SC2016,SC2089	# this is meant to be litterall!
    export SUDOCMD='sudo env "PATH=$PATH"'
  
    echo "Recommended is to run as root (sudo $). Running as $(whoami) has turned out to cause issues in some cases."
    echo "Press enter to continue or CTRL-C to exit"
    read -r
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
    echo "DBG: '$guid' valid GUID"
    return 0
  else
    echo "DBG: '$guid' is invalid GUID"
    return 1
  fi
}

function validate_not_empty() {
  local value="$1"
  if [[ -n "$value" ]]; then
    return 0
  else
    return 1
  fi
}


function prompt_if_missing() {
  local var_name="$1"
  local var_type="$2:-var}"     #var, secret
  local prompt_text="${3:-Enter value for variable '$var_name'}"
  local env_file="${4:-.env}"
  local validate_fn=${5:-}

  local current_value="${!var_name}"
  local read_params=""
  if [[ "$var_type^^" == "SECRET" ]]; then read_params="-s "; fi

  echo "DBG: current value for var $var-name is '$current_value'."
  while [ -z "$current_value" ] || { [ -n "$validate_fn" ] && ! $validate_fn "$current_value"; }; do
    read $read_params -p "$prompt_text: " current_value
  done

  export "$var_name"="$current_value"

  # Save to env-file
  if [[ "${var_type^^}" != "SECRET" ]]; then
    if grep -q "^export $var_name=" "$env_file" 2>/dev/null; then
      sed -i "s|^export $var_name=.*|export $var_name=\"$current_value\"|" "$env_file"
    else
      echo "export $var_name=\"$current_value\"" >> "$env_file"
    fi
  fi
}


function install_if_missing() {
  local installer="${1:-}"	# installer: apt, dnf, yum, packman, snap, brew (auto means, let the function figure out...)
  local tool="$2"		# name of the tool (or keyword 'package' in case of a command-less package)
  local package="${3:-$tool}"	# package to be installed 
  local verify_cmd=$(trim "$4")	# optional

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
    snap)	sudo snap install "$package" ;;
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
    assert $verify_cmd
  fi

  if command -v "$tool" >/dev/null 2>&1; then
    echo "✅ Successfully installed $tool."
    return 0
  else
    echo "❌ Failed to install $tool."
    return 1
  fi
}

