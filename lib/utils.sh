#! /bin/bash
echo "[DEBUG] sourcing $(realpath "${BASH_SOURCE[0]}")"

##
## Library with several functions and utils
##

######## INCLUDES ##########################################
. "${LIB_PATH:-../env}/logging.sh"

######## CONFIG ############################################
SUDOCMD=""      # default value


######## FUNCTIONS #########################################
#
# switch to sudo if not done yet
#
strongly_advice_root() {
  local timeout=${1:-5}

  if [[ "$(id -u)" -eq 0 ]];then
    log "$LOG_DBG" "Running as root, so all fine."
    export SUDOCMD=""
  else
    # let's check whether user can sudo (and cache the password for further sudo commands in the script)
    echo "Enter sudo password to check sudo permissions"
    sudo echo "sudo ok"
    log "$LOG_DBG" "Running as '$(whoami)', but capable of sudo to root"
    # shellcheck disable=SC2016,SC2089  # this is meant to be litterall!
    export SUDOCMD='sudo env "PATH=$PATH"'

    log "$LOG_INF" "Recommended is to run as root (sudo $(basename "$0"))."
    # bij set -e: timeout van read -t geeft exitcode 1 → altijd afvangen met `|| true`
    read -r -t "$timeout" -p "Press enter to continue or Ctrl+C to abort (script will automatically continue in $timeout seconds) ... " <> /dev/tty || true
    log "$LOG_INF" "Continuing..."
  fi
}

##
## Functions
##

function cleanup_file() {
  local filename="${1?Mandatory param 'filename' is missing in call to function cleanup_file}"
  # shellcheck disable=SC2090         # this is meant to be a command, so quoting would have wrong effect
  if ! $SUDOCMD rm -rf "$filename"; then
    exit "$?"
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


function get_version_levels() {
  local version=${1?Parameter 'version' is missing in call to function 'get_version_levels'}
  local levels=${2:-99}

  local IFS='.'
  read -ra parts <<< "$version"   # split version by '.'

  # build output with requested levels, ignoring extra parts
  local result=""
  for ((i=0; i<levels && i<${#parts[@]}; i++)); do
    if [[ $i -gt 0 ]]; then
      result+="."
    fi
    result+="${parts[i]}"
  done

  echo "$result"
}

function assert() {
  log "$LOG_TRC" "asserting command: '$*'"
  bash -c "$*" || {
    local result=$?
    die $result "$LOG_ERR" "Command '$*' FAILED!"
  }
  log "$LOG_DBG" "Command '$*' succeeded"
}

function validate_guid() {
  local guid=${1?Parameter 'guid' is missing in call to function 'validate_guid'}
  if [[ "$guid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
    log "$LOG_TRC" "'$guid' is valid GUID"
    return 0
  else
    log "$LOG_WRN" "'$guid' is invalid GUID"
    return 1
  fi
}

function validate_not_empty() {
  local value="${1?-Parameter 'value' is missing in call to function 'validate_not_empty'}"
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
  log "$LOG_DBG" "prompt_if_missing( varname='$1', vartyp='${2:-}', prompt='${3:-}', env_file='${4:-}', validate_fn='${5:-}') - START"
  local var_name="${1?Parameter 'var_name' is missing in call to function 'prompt_if_missing'}"
  local var_type="${2:-VAR}"     #var, secret
  var_type=${var_type^^}
  local prompt_text="${3:-Enter value for variable $var_name}"
  local env_file="${4:-}"
  local validate_fn=${5:-validate_not_empty}

  log "$LOG_TRC" "var_name='$var_name'"
  # bij set -u: indirecte expansie veilig maken (geen error als var unset is)
  local current_value="${!var_name-}"
  log "$LOG_TRC" "curr_val='$current_value'"
  local read_params=""
  if [[ "${var_type^^}" == "SECRET" ]]; then read_params="-s "; fi

  # Prompt once if value is missing
  if [[ -z "$current_value" ]] || ! $validate_fn "$current_value"; then
    # shellcheck disable=SC2229,SC2086
    read -r $read_params -p "$prompt_text: " current_value
    [[ "$var_type" == "SECRET" ]] && echo ""

    # Validate if needed (loop until valid)
    if ! $validate_fn "$current_value"; then
      while ! $validate_fn "$current_value"; do
        # shellcheck disable=SC2229,SC2086
        read -r $read_params -p "$prompt_text: " current_value
        if [[ "${var_type^^}" == "SECRET" ]]; then echo ""; fi  # add linefeed after secret input
      done
    fi

    #log "$LOG_CMD" "export $var_name=\"$current_value\"" # WARNING: this command shows also secrets on the output!
    # bij set -u veilig exporteren met quotes
    export "$var_name=$current_value"

    # Save to env-file
    if [[ "${var_type^^}" != "SECRET" && -n "${env_file:-}" ]]; then
       save_env_var "$var_name" "$current_value" "$env_file"
    fi
  fi
  log "$LOG_TRC" "prompt_if_missing() - FINISHED"
}

function save_env_var() {
  local var_name=${1?Parameter 'var_name' is missing in call to function 'save_env_var'}
  local curr_val=${2?Parameter 'curr_val' is missing in call to function 'save_env_var'}
  local env_file=${3?Parameter 'env_file' is missing in call to function 'save_env_var'}

  # Save to env-file
  if grep -q "^export $var_name=" "$env_file" 2>/dev/null; then
    log "$LOG_TRC" "updating var '$var_name' to env file '$env_file'"
    sed -i "s|^export $var_name=.*|export $var_name=\"$curr_val\"|" "$env_file"
  else
    log "$LOG_TRC" "adding var '$var_name' to env file '$env_file'"
    echo "export $var_name=\"$curr_val\"" >> "$env_file"
  fi
}

function install_if_missing() {
  local installer tool package verify_cmd
  installer="${1:-}"            							# installer: apt, dnf, yum, packman, snap, brew (auto means, let the function figure out...)
  tool="${2?Parameter 'tool' is missing in call to function 'install_if_missing'}"	# name of the tool (or keyword 'package' in case of a command-less package)
  package="${3:-$tool}"         							# package to be installed
  verify_cmd=$(trim "${4:-}")   							# optional

  hash -r  # Clear cached command locations

  # Check package by installer if no binary or force set
  local installed=false
  if [[ "${tool^^}" == "PACKAGE" ]]; then
    case "$installer" in
      apt)      dpkg -s "$package" &>/dev/null && installed=true ;;
      dnf|yum)  rpm -q "$package" &>/dev/null && installed=true ;;
      pacman)   pacman -Qi "$package" &>/dev/null && installed=true ;;
      snap)     snap list | grep -q "^$package " && installed=true ;;
      brew)     brew list --formula | grep -qx "$package" && installed=true ;;
      auto)     echo "" ;; # No check implemented, just installed
      *)        echo "❌ Unsupported installer: $installer"; return 1 ;;
    esac
  else
   if command -v "$tool" >/dev/null 2>&1; then
    installed=true
   fi
  fi

  if $installed; then
    log "$LOG_DBG" "✅ $tool ($package) is already installed."
    return 0
  fi

  log "$LOG_INF" "🔍 $tool ($tool) not found. Attempting to install ${package}..."

  case "$installer" in
    apt)        sudo apt update && sudo apt install -y "$package" ;;
    apt-get)    sudo apt-get update && sudo apt-get install -y "$package" ;;
    snap)       sudo snap install "$package" || sudo snap install "$package" --classic ;;
    dnf)        sudo dnf install -y "$package" ;;
    yum)        sudo yum install -y "$package" ;;
    pacman)     sudo pacman -Sy --noconfirm "$package" ;;
    brew)       brew install "$package" ;;
    auto)       # Auto-detect installer
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
                  die 1 "❌ Could not find a supported package manager to install $tool."
                fi
                ;;
      *)        die 1 "❌ Unsupported installer: $installer"  ;;
  esac

  if [[ -n "$verify_cmd" ]]; then
    log "$LOG_DBG" "Verify ($verify_cmd):"
    assert "$verify_cmd"
  fi

  if command -v "$tool" >/dev/null 2>&1; then
    log "$LOG_INF" "✅ Successfully installed $tool."
    return 0
  else
    log "$LOG_ERR" "❌ Failed to install $tool."
    return 1
  fi
}

function install_kind_if_missing() {

  if [[ -f "/usr/local/bin/kind" ]]; then
    log "$LOG_DBG" "✅ kind (Kubernetes in Docker) is already installed."
    return 0
  fi

  ## Install KinD
  # For AMD64 / x86_64
  log "$LOG_INF" "Installing kind (Kubernetes in Docker)..."
  [ "$(uname -m)" = "x86_64" ] && curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
  log "$LOG_INF" "...done\n"
}


function install_pack_if_missing() {
  local command="pack"
  local version="$PACK_VERSION"
  local url="https://github.com/buildpacks/pack/releases/download/v${version}/pack-v${version}-linux.tgz"
  local bin_folder="/usr/local/bin"

  if [[ -f "$bin_folder/$command" ]]; then
    log "$LOG_DBG" "✅ $command is already installed."
    return 0
  fi

  log "$LOG_INF" "Installing $command ..."
  curl -sL "$url" | tar -xzv
  sudo mv pack /usr/local/bin
  log "$LOG_INF" "...done"
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
      *)   die 1 "Error: unknown or invalid unit '$unit'" ;;
    esac

    rest="${rest#"$matched"}"
  done

  if [[ -n $rest ]]; then
    die 1 "Error: leftover unparsed input: '$rest'"
  fi

  echo "$total"
}

