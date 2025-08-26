#!/bin/bash
#==============================================================================
#
# This bash library contains some function for logging.
#
#==============================================================================
# History:
#
# 02/11/2022 |        | R. Niesten | Initial version
# 19/08-2025 |        | R. Niesten | 
#==============================================================================

#==== Configuration ===========================================================


#==== Some general folders ====================================================
TMP_DIR="${TMP_DIR:-$(mktemp -d)}"
export TMP_DIR

trap 'cleanup' EXIT

#==== Modular variables and constants ==========================================

## logging levels
export LOG_ERR=0
export LOG_WRN=1
export LOG_INF=2
export LOG_DBG=3
export LOG_TRC=4
export LOG_TR5=5
export LOG_CMD=6
export LOG_ALL=9
export log_level="${log_level:-LOG_INF}"
export log_level_to_file="${log_level_to_file:-LOG_TRC}"
export log_always_commands=${log_always_commands:-false}
export show_timestamps=${show_timestamps:-false}
export logfile=""


#==== functions ===============================================================

#
# Usage:   die <error-message>
#
# Purpose: this function ends the script with the given error number. Before this,
#          it retrieves the current stack and shows the given error message followed
#          by the stack.
#
# Author:  R. Niesten 03-02-2023
#
function die () {
  rc="${1:-}"
  shift
  get_stack "$*" 1	# skip the (1) line in the stack for the die function
  log "$LOG_ERR" "${STACK}"
  exit "$rc"
}


#
# Usage:   log <level>  <log-msg>
#
# Purpose: this function logs the provided log-message to the console and to file.
#          It used the functions log_to_console and log_to_file for the actual logging.
#
# Params:  level;   $LOG_ERR, $LOG_WRN, $LOG_INF, $LOG_DBG, $LOG_TRC, $LOG_TRC5, $LOG_CMD
#          log-msg: the string to be logged
#
# Author:  R. Niesten 03-02-2023
#
function log () {
  local level="${1?Parameters 'level' missing in call to function 'log()'}"
  local txt="${2:-}"

  log_to_console "$level" "$txt"
  log_to_file "$level" "$txt"
}


#
# Usage:   log_to_console <level>  <log-msg>
#
# Purpose: This function logs the provided log-message to the console. Only messages
#          that have level equal or higher to the set log_level will actually be printed
#          (ERR is lowest and levels get higher as described at param 'level'.
#          If on the actual console, it will show the log entries in colors.
#          Some helper function/variables to tweak the output
#          - log_level (func setloglevel()) to set the max log level to be printed
#          - log_always_commands=true to always print log entries of the $LOG_CMD regardless
#            of the set log_level
#          - show_timestamps=true to prepend a timestamp to the log entry
#          Please note that in case this function can't write to the console, it will write 
#          the log entry to the logfile (and will auto-create a logfile if not defined yet)
#
# Params:  level;   $LOG_ERR, $LOG_WRN, $LOG_INF, $LOG_DBG, $LOG_TRC, $LOG_TRC5, $LOG_CMD
#          log-msg: the string to be logged
#
# Author:  R. Niesten 03-02-2023
#
function log_to_console(){
  local level="${1?Parameters 'level' missing in call to function 'log()'}"
  local txt="${2:-}"

  local levelstr=('[ERROR  ] ' '[WARNING] ' '' '[DEBUG  ] ' '[TRACE  ]  ' '[trace  ] ' '[COMMAND] ')
  local timestamp=""
  local print_to_tty=false
  local defaultcolor=''

  if [[ "$level" -le "$log_level" ]]; then
    print_to_tty=true
  elif [[ "$level" -eq "$LOG_CMD" && "$log_always_commands" == "true" ]]; then
    print_to_tty=true
  fi

  if [[ -t 0 ]]; then
    __clr_default='\e[39m'
    __clr_black='\e[30m'
    __clr_red='\e[31m'
    __clr_green='\e[32m'
    __clr_yellow='\e[33m'
    __clr_blue='\e[34m'
    __clr_magenta='\e[35m'
    __clr_cyan='\e[36m'
    __clr_lt_gray='\e[37m'
    __clr_dark_gray='\e[90m'
    __clr_lt_red='\e[91m'
    __clr_lt_green='\e[92m'
    __clr_lt_yellow='\e[93m'
    __clr_lt_blue='\e[94m'
    __clr_lt_magenta='\e[95m'
    __clr_lt_cyan='\e[96m'
    __clr_white='\e[97m'

    #           error           warning         info            debug           trace           trace5              command
    logcolor=( "$__clr_red" "$__clr_lt_yellow" "$__clr_default" "$__clr_blue" "$__clr_dark_gray" "$__clr_dark_gray" "$__clr_lt_cyan" ) # see https://misc.flogisoft.com/bash/tip_colors_and_formatting
    defaultcolor=$__clr_default
  else
    logcolor=('' '' '' '' '' '' '')
    defaultcolor=''
  fi

  if [[ "$show_timestamps" == "true" ]]; then
    timestamp="$(date '+%F %T') "
  fi

  if [[ "$print_to_tty" == "true" ]]; then
    if [[ "$$" -eq "$BASHPID" ]]; then
      # if code is running in 'main' shell, just echo ...
      echo -e "${logcolor[$level]}${timestamp}${levelstr[$level]}${txt}${defaultcolor}"
    else
      # ... if the code is running in a subshell, output to /dev/tty (unless no tty is available, e.g. when running in Nagios)
      if [ "$(tty)" != "not a tty" ];then
        echo -e "${logcolor[$level]}${levelstr[$level]}${txt}${defaultcolor}" >/dev/tty
        # However, writing to tty causes an error when no tty is set (which is e.g. the case in nagios), which in combination with
        # (recommended) command "set -e" causes the script to stop. Not a desired behaviour.
      else
        # if there is no tty (which is the case when running a plugin from nagios), don't write to console at all!
        # If no logfile is set yet, it will implicitly set now, so log entry will be written to logfile later in this function
        if [[ -z $logfile ]]; then
          logfile=$(/bin/mktemp "/tmp/autolog.XXXX.log")
          log_level_to_file=$(max "$log_level_to_file" "$log_level")
	  log_to_file "$level" "Logfile created because code can't write to tty in subshell for script '$(basename "$0")'"
        fi
      fi
    fi
  fi
}


#
# Usage:   log_to_file <level>  <log-msg>
#
# Purpose: This function logs the provided log-message to the specified logfile. Only messages
#          that have level equal or higher to the set log_level will actually be printed
#          (ERR is lowest and levels get higher as described at param 'level'.
#          If no logfile is specified, no action will be taken.
#          Some helper function/variables to tweak the output
#          - log_level (func setloglevel()) to set the max log level to be printed
#          - log_always_commands=true to always print log entries of the $LOG_CMD regardless
#            of the set log_level
#          - show_timestamps=true to prepend a timestamp to the log entry (always for entries to file)
#          - logfile to specify the name and path of the logfile
#
#          Please note that in case this function can't write to the console, it will write
#          the log entry to the logfile (and will auto-create a logfile if not defined yet)
#
# Params:  level;   $LOG_ERR, $LOG_WRN, $LOG_INF, $LOG_DBG, $LOG_TRC, $LOG_TRC5, $LOG_CMD
#          log-msg: the string to be logged
#
# Author:  R. Niesten 03-02-2023
#
function log_to_file(){
  local level="${1?Parameters 'level' missing in call to function 'log()'}"
  local txt="${2:-}"

  local print_to_file=false

  if [[ -n "${logfile:-}" ]]; then
    if [[ "$level" -le "$log_level" ]]; then
      print_to_file=true
    elif [[ "$level" -eq "$LOG_CMD" && "$log_always_commands" == "true" ]]; then
      print_to_file=true
    fi
  fi

  local levelstr=('[ERROR  ] ' '[WARNING] ' '' '[DEBUG  ] ' '[TRACE  ]  ' '[trace  ] ' '[COMMAND] ')

  if [[ "$print_to_file" == "true" ]]; then					# if level is less than log_level_to_file is and logfile is set...
    printf '%s | %-7s | %s\n' "$(date '+%F %T')" "${levelstr[$level]}" "$txt" >> "$logfile"     # then write to logfile
  fi
}


#
# Usage:   set_logfile <logfile> [<log-level>
#
# Purpose: This function specifies the name and path of the logfile and optionally
#          the max log level for the file (can be different from level for console!
#
# Author:  R. Niesten 03-02-2023
#
function set_logfile() {
  local __logfile="${1?Param 'logfile' in call to function 'set_logfile()' is missing}"
  local __loglevel="${2:-}"

  if [ ! -f "$__logfile" ]; then
    touch "$__logfile"
  fi
  export logfile="$__logfile"

  if [ -n "$__loglevel" ];then
    if [[ "$__loglevel" =~ ^[0-9]+$ ]]; then
      log_level_to_file="$__loglevel"
    else
      die 1 "Invalid log level '$__loglevel', must be a digit!"
    fi
  fi
}

#
# Usage:   setloglevel<log-level
#
# Purpose: This function specifies the name and path of the logfile and optionally
#          the max log level
#
# Author:  R. Niesten 03-02-2023
#
function setloglevel() {
  local __loglevel="${1?Param 'loglevel' in call to function 'setloglevel()' is missing}"

  if [ -n "$__loglevel" ]; then
    case $__loglevel in
      +) export log_level=$((log_level+1)) ;;
      -) export log_level=$((log_level-1)) ;;
      0|1|2|3|4|5|6|7|8|9)
         export log_level=$__loglevel ;;
      *) die 1 "Invalid log level '$__loglevel', syntax: setloglevel [+-123456789]"
    esac
  fi
}


#
# Usage:   min <val1> <val2>
#
# Purpose: This function returns the lowest value.
#
# Author:  R. Niesten 03-02-2023
#
min() {
  #TODO: param valudation
  echo $(( $1 < $2 ? $1 : $2 ))
}


#
# Usage:   min <val1> <val2>
#
# Purpose: This function returns the highest value.
#
# Author:  R. Niesten 03-02-2023
#
max() {
  #TODO: param validation
  echo $(( $1 > $2 ? $1 : $2 ))
}


#
# Usage:   get_stack <error-message> [<skip>]
#
# Purpose: fills the variable $STACK with the errormessage, followed by a java like stacktrace
#          which can be used later to print or log. skip is an optional parameter that defines
#          the number of stack entries to skip from adding to the global variable STACK (e.g. 
#          skipping the function that does the errorhandling, so the stack shows to actual  
#          location (function, filename, line-number) of the error on the first line.
#
# License: MIT, wtfpl or whatever OSS license you like
#
# Source:  https://gist.github.com/akostadinov/33bb2606afe1b334169dfbf202991d36
#
function get_stack () {
  STACK=""
  local message="${1:-""}"
  local skip="${2:-0}"
  local stack_size=${#FUNCNAME[@]}
  # to avoid noise we start with 1 to skip the get_stack function
  for (( i=1+skip; i<stack_size; i++ )); do
    local func="${FUNCNAME[$i]}"
    [[ $func = "" ]] && func=MAIN
    local linen="${BASH_LINENO[$(( i - 1 ))]}"
    local src="${BASH_SOURCE[$i]}"
    [[ "$src" = "" ]] && src=non_file_source

    STACK+=$'\n'"   at: $func $src $linen"
  done
  STACK="${message}${STACK}\n"
}


#
# Usage:   mktemp [OPTION]... [TEMPLATE]
#
# Purpose: a wrapper around /bin/mktemp that ensures all tempfiles are automatically
#          stored in $TMP_DIR, which will be cleaned up after the script exists
#
# Author:  R. Niesten 03-02-2023
#
mktemp() {
  cmd="/bin/mktemp"
  args=""
  template="XXXXXX"

  while [ $# -gt 0 ];do
    if [[ "${1:0:1}" == "-" ]]; then
      args+="$1 "
    else
      template="$1"
    fi
    shift
  done

  template="${TMP_DIR:-/tmp}/${template}"

  # shellcheck disable=SC2086	# $args is supposed to be blobbed and splitted as these are args
  $cmd $args "$template"
}


#
# Usage:   cleanup
#
# Purpose: remove the temp folder /tmp/$TMP_DIR that has been created for this script recursively
#          this function is automatically executed whenever the script finishes (in whatever way)
#
# Author:  R. Niesten 03-02-2023
#
# History:
# 06-11-2023 | 337717 | R. Niesten | Don't fail if temp folder doesn't exist (anymore)
#
cleanup() {
  log "$LOG_TR5" "cleanup temp-folder '$TMP_DIR':\n$(ls -la "$TMP_DIR" 2>/dev/null || echo "(empty folder)")"
  if [[ -d "$TMP_DIR" ]]; then
    rm -R "$TMP_DIR"
    log "$LOG_TR5" "temp-folder '$TMP_DIR' is removed."
  else
    log "$LOG_TR5" "temp-folder '$TMP_DIR' doesn't exist anymore, nothing to cleanup."
  fi
}



#==== function to process args to set modular variables ========================

#
# Usage:   logging__parse_arg
#
# Purpose: parses the provide argument (potentially including values) and returns the number of items
#          it has consumed via global variable __LOGGING__ARTS_CONSUMED('--switch is 1 item, '-key value' is 2 items)
#
# Return values:
#	   0 - arg was parsed
#	   1 - arg was not a logging arg, so nothing is processed
#         >1 - failure while processing an arg
#
# Author:  R. Niesten
#
logging__parse_arg() {
  local arg="$1"
  local val="${2:-}"
  __LOGGING__ARGS_CONSUMED=0

  if (( BASH_SUBSHELL > 0 )); then
    die "Function logging__parse_arg() must be called in the main shell, not in a subshell)"
  fi
  
  case "$arg" in
    -l|--loglevel)            setloglevel "$val";       log "$LOG_TR5" "handled '-l $val' in logging library";		__LOGGING__ARGS_CONSUMED=2;  ;;
    --loglevel=*)             setloglevel "${arg#*=}";  log "$LOG_TR5" "handled '-l=${arg#*=}' in logging library";	__LOGGING__ARGS_CONSUMED=1;  ;;
    -c|--log-always-commands) log_always_commands=true; log "$LOG_TR5" "handled '-c' in logging library";       	__LOGGING__ARGS_CONSUMED=1;  ;;
    -f|--logfile)             set_logfile "$val";       log "$LOG_TR5" "handled '-f $val' in logging library";    	__LOGGING__ARGS_CONSUMED=2;  ;;
    --logfile=*)              set_logfile "${arg#*=}"   log "$LOG_TR5" "handled '-f=${arg#*=}' in logging library";	__LOGGING__ARGS_CONSUMED=1;  ;;
    -t|--show-timestamps)     show_timestamps=true;     log "$LOG_TR5" "handled '-t' in logging library";            	__LOGGING__ARGS_CONSUMED=1;  ;;
    -v|--verbose)             setloglevel '+';          log "$LOG_TR5" "handled '-v' in logging library";            	__LOGGING__ARGS_CONSUMED=1;  ;;
    *)                                                  log "$LOG_TR5" "ignored '$arg' in logging library";		return 1 ;; # arg is not for logging library
  esac
}

logging__get_args() {
  echo " [ logging-args ]"
}

logging__show_args_desc() {
  local indent="${1:-2}"
  local pad=$(printf '%*s' "$indent")

  echo "
${pad}Logging-args:
${pad}  -c|--loglevel <level>;    one of: LOG_ERR, LOG_WRN, LOG_INF, LOG_DBG, LOG_TRC, LOG_TR5, LOG_CMD, LOG_ALL
${pad}                            of a number between 0 (LOG_ERR)  and 6 (LOG_CMD).
${pad}                            All log entry up to the specified level will be displayed on the console.
${pad}                            LOG_ALL will display all entries.
${pad}  -v|--verbose;             Increases current log level by 1
${pad}  -f|--logfile=<filename>;  path and filename of logfile
${pad}  -c|--log-always-commands; when set, command (LOG_CMD) will be logged in screen regardless specified log level
${pad}  -t|--show-timestamps;     log entries on screen are prepended with the timestamp of the entry
"
}
