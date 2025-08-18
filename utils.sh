#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SUDOCMD=""  # default value

#
# switch to sudo if not done yet
#
strongly_advice_root() {
  local timeout=${1:-10}

  if [[ "$(id -u)" -eq 0 ]]; then
    echo "Running as root, so all fine."
    export SUDOCMD=""
  else
    echo "Enter sudo password to check sudo permissions"
    sudo echo "sudo ok"
    echo "Running as '$(whoami)', but capable of sudo to root"
    export SUDOCMD='sudo env "PATH=$PATH"'

    echo "Recommended is to run as root (sudo $). Running as non-root user like '$(whoami)' might cause issues."
    # read -t geeft status 1 bij timeout → || true voorkomt exit door set -e
    read -r -t "$timeout" -p \
      "Press enter to continue or Ctrl+C to abort (script will automatically continue in $timeout seconds) ... " \
      <> /dev/tty || true
    echo "Continuing..."
  fi
}

cleanup_file() {
  local filename="${1:-}"  # voorkomt set -u error als geen parameter
  if [[ -n "$filename" && -f "$filename" ]]; then
    $SUDOCMD rm -rf "$filename"
  fi
}

trim() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo "$var"
}

get_version_levels() {
  local version="${1:-}"  # voorkomt unset variable
  local levels="${2:-0}"  # default 0 levels
  local IFS='.'
  read -ra parts <<< "$version" || true  # || true → geen exit bij lege input
  local result=""
  for ((i=0; i<levels && i<${#parts[@]}; i++)); do
    ((i>0)) && result+="."
    result+="${parts[i]}"
  done
  echo "$result"
}

assert() {
  bash -c "$*" || { echo "Command '$*' FAILED!"; exit 1; }
  echo "Command '$*' succeeded"
}

validate_guid() {
  local guid="${1:-}"  # voorkomt set -u crash
  [[ "$guid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validate_not_empty() {
  local value="${1:-}"
  [[ -n "$value" ]]
}

validate_dummy() {
  return 0
}

prompt_if_missing() {
  local var_name="${1:-}"               # voorkomt set -u
  local var_type="${2:-VAR}"
  var_type=${var_type^^}
  local prompt_text="${3:-Enter value for variable $var_name}"
  local env_file="${4:-}"
  local validate_fn="${5:-validate_not_empty}"

  # "${!var_name-}" voorkomt set -u crash bij indirecte expansie
  local current_value="${!var_name-}"
  local read_params=""
  if [[ "$var_type" == "SECRET" ]]; then read_params="-s "; fi

  if [[ -z "$current_value" ]] || ! $validate_fn "$current_value"; then
    read -r $read_params -p "$prompt_text: " current_value || true
    [[ "$var_type" == "SECRET" ]] && echo ""

    while ! $validate_fn "$current_value"; do
      read -r $read_params -p "$prompt_text: " current_value || true
      [[ "$var_type" == "SECRET" ]] && echo ""
    done

    export "$var_name=$current_value"

    if [[ "$var_type" != "SECRET" && -n "$env_file" ]]; then
      save_env_var "$var_name" "$current_value" "$env_file"
    fi
  fi
}

save_env_var() {
  local var_name="${1:-}"
  local curr_val="${2:-}"
  local env_file="${3:-}"

  if [[ -z "$var_name" || -z "$env_file" ]]; then
    return 1
  fi

  if grep -q "^export $var_name=" "$env_file" 2>/dev/null; then
    sed -i "s|^export $var_name=.*|export $var_name=\"$curr_val\"|" "$env_file"
  else
    echo "export $var_name=\"$curr_val\"" >> "$env_file"
  fi
}

install_if_missing() {
  local installer="${1:-}"
  local tool="${2:-}"
  local package="${3:-$tool}"
  local verify_cmd
  verify_cmd=$(trim "${4:-}")

  hash -r

  local installed=false
  if [[ "${tool^^}" == "PACKAGE" ]]; then
    case "$installer" in
      apt)      dpkg -s "$package" &>/dev/null && installed=true ;;
      dnf|yum)  rpm -q "$package" &>/dev/null && installed=true ;;
      pacman)   pacman -Qi "$package" &>/dev/null && installed=true ;;
      snap)     snap list | grep -q "^$package " && installed=true ;;
      brew)     brew list --formula | grep -qx "$package" && installed=true ;;
      auto)     ;; # geen check
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

  echo "🔍 $tool ($tool) not found. Installing ${package}..."

  case "$installer" in
    apt)        sudo apt update && sudo apt install -y "$package" ;;
    apt-get)    sudo apt-get update && sudo apt-get install -y "$package" ;;
    snap)       sudo snap install "$package" || sudo snap install "$package" --classic ;;
    dnf)        sudo dnf install -y "$package" ;;
    yum)        sudo yum install -y "$package" ;;
    pacman)     sudo pacman -Sy --noconfirm "$package" ;;
    brew)       brew install "$package" ;;
    auto)       if command -v apt-get >/dev/null; then
                  sudo apt-get update && sudo apt-get install -y "$package"
                elif command -v snap >/dev/null; then
                  sudo snap install "$package"
                elif command -v dnf >/dev/null; then
                  sudo dnf install -y "$package"
                elif command -v yum >/dev/null; then
                  sudo yum install -y "$package"
                elif command -v pacman >/dev/null; then
                  sudo pacman -Sy --noconfirm "$package"
                elif command -v brew >/dev/null; then
                  brew install "$package"
                else
                  echo "❌ No supported package manager for $tool."
                  return 1
                fi ;;
      *)        echo "❌ Unsupported installer: $installer"; return 1 ;;
  esac

  [[ -n "$verify_cmd" ]] && assert "$verify_cmd"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "✅ Successfully installed $tool."
  else
    echo "❌ Failed to install $tool."
    return 1
  fi
}

install_go_if_missing() {
  install_if_missing snap go go "go version"
}

install_kind_if_missing() {
  if [[ -f "/usr/local/bin/kind" ]]; then
    echo "✅ kind already installed."
    return 0
  fi
  echo "Installing kind..."
  [ "$(uname -m)" = "x86_64" ] && curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
  echo "...done"
}

install_pack_if_missing() {
  local version="${PACK_VERSION:-}"  # voorkomt unset
  local command="pack"
  local url="https://github.com/buildpacks/pack/releases/download/v${version}/pack-v${version}-linux.tgz"
  local bin_folder="/usr/local/bin"

  if [[ -f "$bin_folder/$command" ]]; then
    echo "✅ $command is already installed."
    return 0
  fi

  echo "Installing $command ..."
  curl -sL "$url" | tar -xzv
  sudo mv pack /usr/local/bin
  echo "...done"
}

duration2sec() {
  local input="${1:-}"  # voorkomt unset
  input="${input// /}"
  local total=0
  local rest="$input"

  while [[ $rest =~ ^([0-9]+)([a-z]*) ]]; do
    local number="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      "")  (( total += number )) ;;
      s)   (( total += number )) ;;
      m)   (( total += number * 60 )) ;;
      h)   (( total += number * 3600 )) ;;
      d)   (( total += number * 86400 )) ;;
      w)   (( total += number * 604800 )) ;;
      ms)  (( total += number / 1000 )) ;;
      us)  (( total += number / 1000000 )) ;;
      *)   echo "Error: invalid unit '$unit'" >&2; return 1 ;;
    esac
    rest="${rest#${BASH_REMATCH[0]}}"
  done

  [[ -n "$rest" ]] && { echo "Error: leftover '$rest'" >&2; return 1; }
  echo "$total"
}

