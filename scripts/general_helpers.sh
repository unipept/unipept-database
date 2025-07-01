################################################################################
# reportProgress                                                               #
#                                                                              #
# Logs the progress of an ongoing task as a percentage. The progress value     #
# can either be passed as an argument or provided through stdin. If the        #
# progress is indeterminate or continuously updated, it can be streamed        #
# through stdin.                                                               #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Progress value as a percentage (0-100). Use "-" to read from stdin    #
#   $2 - A description or label for the task being logged                      #
#                                                                              #
# Outputs:                                                                     #
#   Progress message with the format "<label> -> <progress>%" to stdout        #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
reportProgress() {
  # Value between 0 and 100 (-1 for indeterminate progress)
  if [[ "$1" == "-" ]]
  then
    while read -r PROGRESS
    do
      log "$2 -> ${PROGRESS}%"
    done
  else
    PROGRESS="$1"
    log "$2 -> ${PROGRESS}%"
  fi
}

################################################################################
# checkdep                                                                     #
#                                                                              #
# Checks if a specific dependency is installed on the current system. If the   #
# dependency is missing, an error message is displayed, indicating to the user #
# what needs to be installed. The script exits with status code 6 if the       #
# dependency is not met.                                                       #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Name of the dependency to check (must be recognizable by the system)  #
#   $2 (optional) - Friendly name of the dependency to display in the error    #
#                   message if it's missing                                    #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr if the dependency is not found                     #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 6 if the dependency is not installed                #
################################################################################
checkdep() {
    which "$1" > /dev/null 2>&1 || hash "$1" > /dev/null 2>&1 || {
        echo "This script requires ${2:-$1} to be installed." >&2
        exit 6
    }
}

################################################################################
# log                                                                          #
#                                                                              #
# Logs a timestamped message to standard output. The format includes an epoch  #
# timestamp, date, and time for better traceability of script activity.        #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $@ - The message to log                                                    #
#                                                                              #
# Outputs:                                                                     #
#   The timestamped log message to stdout                                      #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
log() { echo "$(date +'[%s (%F %T)]')" "$@"; }
