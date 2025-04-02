################################################################################
# This file contains a collection of variables and helper functions shared     #
# between the `generate_sa_tables.sh` and `generate_umgap_tables.sh` scripts.  #
################################################################################

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"


################################################################################
#                            Helper Functions                                  #
################################################################################

################################################################################
# clean                                                                        #
#                                                                              #
# This function removes all temporary files that have been created by this     #
# script. It cleans the contents of the temporary directory and resets the     #
# TMPDIR environment variable to its original value.                           #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory used to store temporary files                #
#   UNIPEPT_TEMP_CONSTANT - The constant used to create temporary file paths   #
#   OLD_TMPDIR        - Original TMPDIR value to restore                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
clean() {
	# Clean contents of temporary directory
	rm -rf "${TEMP_DIR:?}/$UNIPEPT_TEMP_CONSTANT"
	export TMPDIR="$OLD_TMPDIR"
}

################################################################################
# terminateAndExit                                                             #
#                                                                              #
# Stops the script and removes all temporary files that are created by this    #
# script. Prints an error message to stderr and exits with status code 1.      #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr                                                   #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
terminateAndExit() {
	echo "Error: execution of the script was cancelled by the user." 1>&2
	echo ""
	clean
	exit 1
}

################################################################################
# errorAndExit                                                                 #
#                                                                              #
# Can be called when an error has occurred during the execution of the script. #
# This function will inform the user of what error occurred, where it occurred,#
# and what command was being executed when it happened. It will then properly  #
# exit the script, cleaning up any temporary files first.                      #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory used to store temporary files                #
#   UNIPEPT_TEMP_CONSTANT - The constant used to create temporary file paths   #
#   OLD_TMPDIR        - Original TMPDIR value to restore                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 (optional)     - Additional error message to display                    #
#                                                                              #
# Outputs:                                                                     #
#   Error details to stderr                                                    #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 2                                                  #
################################################################################
errorAndExit() {
  local exit_status="$?"        # Capture the exit status of the last command
  local line_no=${BASH_LINENO[0]}  # Get the line number where the error occurred
  local command="${BASH_COMMAND}"  # Get the command that was executed

	echo "Error: the script experienced an error while trying to build the requested database." 1>&2
	echo "Error details:" 1>&2
  echo "Command '$command' failed with exit status $exit_status at line $line_no." 1>&2

	if [[ -n "$1" ]]
	then
	  echo "$1" 1>&2
  fi
	echo "" 1>&2
	clean
	exit 2
}

################################################################################
# printUnknownOptionAndExit                                                    #
#                                                                              #
# Informs the user that the syntaxis provided for this script is incorrect and #
# exits with status code 3.                                                    #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr                                                    #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 3                                                   #
################################################################################
printUnknownOptionAndExit() {
	echo "Error: unknown invocation of script. Consult the information below for more details on how to use this script."
	echo "" 1>&2
	printHelp
	exit 3
}

################################################################################
# checkDirectoryAndCreate                                                      #
#                                                                              #
# Checks if the given specified location is a valid directory. If the given    #
# path points to a non-existing item, a new directory will be created at this  #
# location. The script will exit with status code 4 if an invalid path is      #
# presented.                                                                   #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Path to check or create                                               #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr if the path is invalid                             #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 4 if the path is invalid                            #
################################################################################
checkDirectoryAndCreate() {
	if [[ ! -e "$1" ]]
	then
		mkdir -p "$1"
	fi

	if [[ ! -d "$1" ]]
	then
		echo "The path you provided is invalid: $1. Please provide a valid path and try again." 1>&2
		exit 4
	fi
}

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
# lz                                                                           #
#                                                                              #
# Creates a named pipe (FIFO) for the provided file and prepares it to receive #
# compressed data using the LZ4 algorithm. The compressed output is written    #
# to the specified file. Input to the lz function is uncompressed data.        #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory to store intermediate pipes                  #
#   UNIPEPT_TEMP_CONSTANT - Sub-directory constant for intermediate storage    #
#   CMD_LZ4           - Command or path to the lz4 binary                      #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Path to the file where the compressed output will be stored           #
#                                                                              #
# Outputs:                                                                     #
#   The path to the created FIFO                                               #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
lz() {
	fifo="$(uuidgen)-$(basename "$1")"
	rm -f "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	mkfifo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	echo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	mkdir -p "$(dirname "$1")"
	{ $CMD_LZ4 - < "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" > "$1" && rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" || kill "$self"; } > /dev/null &
}

################################################################################
# luz                                                                          #
#                                                                              #
# Creates a named pipe (FIFO) for the provided file and decompresses data from #
# the file using the LZ4 algorithm. The decompressed output is passed through  #
# the FIFO.                                                                    #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory to store intermediate pipes                  #
#   UNIPEPT_TEMP_CONSTANT - Sub-directory constant for intermediate storage    #
#   CMD_LZ4CAT        - Command or path to the lz4 decompression binary        #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Path to the compressed input file                                     #
#                                                                              #
# Outputs:                                                                     #
#   The path to the created FIFO                                               #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
luz() {
	fifo="$(uuidgen)-$(basename "$1")"
	rm -f "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	mkfifo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	echo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	{ $CMD_LZ4CAT "$1" > "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" && rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" || kill "$self"; } > /dev/null &
}

################################################################################
# have                                                                         #
#                                                                              #
# Checks if all files passed as arguments exist.                               #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $@ - List of file paths to check                                           #
#                                                                              #
# Outputs:                                                                     #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   0 if all files exist, 1 otherwise                                          #
################################################################################
have() {
	if [ "$#" -gt 0 -a -e "$1" ]; then
		shift
		have "$@"
	else
		[ "$#" -eq 0 ]
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
        echo "Unipept database builder requires ${2:-$1} to be installed." >&2
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
