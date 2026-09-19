# shellcheck shell=bash
################################################################################
# Shell functions shared by the pipelines and the OpenSearch loader: logging,  #
# dependency checks, error handling, and the background writers behind lz and  #
# luz. Sourced, never run.                                                     #
################################################################################

# The directory of this file. Not CURRENT_LOCATION, which belongs to the script that sources it.
LIB_DIR="${BASH_SOURCE%/*}"
# shellcheck disable=SC2034 # read by the build scripts that source this file
RUST_BIN_DIR="$LIB_DIR/../../target/release"

################################################################################
#                            Variables and options                             #
################################################################################

# Required to reset the temporary directory after running the script
OLD_TMPDIR="${TMPDIR:-}"

# Some default values for the utilities used by this script
CMD_LZ4="lz4 -c" # Which pipe compression command should I use for .lz4 files?
CMD_LZ4CAT="lz4 -dc" # Which decompression command should I use for .lz4 files?
CMD_AWK="gawk"

# Seconds a background writer may take to finish after its producer has closed the pipe.
WRITER_TIMEOUT=3600

################################################################################
#                            Helper Functions                                  #
################################################################################

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
	# Clean contents of temporary directory, if the calling script uses one
	if [[ -n "${TEMP_DIR:-}" ]]
	then
		rm -rf "${TEMP_DIR:?}/$UNIPEPT_TEMP_CONSTANT"
	fi
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
#   None                                                                       #
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

  report_failed_writers || true

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
# writers_dir                                                                  #
#                                                                              #
# Prints the directory that holds the marker files of the background writers.  #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR, UNIPEPT_TEMP_CONSTANT                                            #
################################################################################
writers_dir() {
	echo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/.writers"
}

################################################################################
# register_writer                                                              #
#                                                                              #
# Records that a background writer has started and returns the path prefix of  #
# its marker file. The writer renames the marker to .ok or .fail when it ends. #
#                                                                              #
# A marker rather than a process id, because lz and luz are called inside a    #
# command substitution: a pid collected there never reaches the shell that has #
# to check it.                                                                 #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR, UNIPEPT_TEMP_CONSTANT                                            #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Name of the FIFO, used to keep the marker unique                      #
#   $2 - What the writer is doing, reported if it fails                        #
#                                                                              #
# Outputs:                                                                     #
#   The marker path without its suffix                                         #
################################################################################
register_writer() {
	local dir
	dir="$(writers_dir)"
	mkdir -p "$dir"
	echo "$2" > "$dir/$1.running"
	echo "$dir/$1"
}

################################################################################
# wait_for_writers                                                             #
#                                                                              #
# Waits until every background writer started so far has ended, then reports   #
# the ones that failed. Call it between pipeline steps: a step that reads what #
# the step before it wrote needs that file to be complete.                     #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR, UNIPEPT_TEMP_CONSTANT, WRITER_TIMEOUT                            #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   One error message per failed writer to stderr                              #
#                                                                              #
# Returns:                                                                     #
#   0 if every writer succeeded, 1 otherwise                                   #
################################################################################
wait_for_writers() {
	local dir
	dir="$(writers_dir)"
	local waited=0

	[[ -d "$dir" ]] || return 0

	while compgen -G "$dir/*.running" > /dev/null
	do
		sleep 1
		waited=$((waited + 1))
		if [[ "$waited" -ge "$WRITER_TIMEOUT" ]]
		then
			echo "Error: a background writer did not finish within $WRITER_TIMEOUT seconds." 1>&2
			return 1
		fi
	done

	report_failed_writers
}

################################################################################
# run_step                                                                     #
#                                                                              #
# Runs one pipeline step, then waits for the background writers it started.    #
# The next step can then read every table this step wrote.                     #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR, UNIPEPT_TEMP_CONSTANT, WRITER_TIMEOUT                            #
#                                                                              #
# Arguments:                                                                   #
#   $@ - The step function and its arguments                                   #
#                                                                              #
# Returns:                                                                     #
#   1 if a writer failed or did not finish, the status of the step otherwise   #
################################################################################
run_step() {
	"$@"
	wait_for_writers
}

################################################################################
# report_failed_writers                                                        #
#                                                                              #
# Reports every background writer that has already failed, without waiting for #
# the ones still running. Used on the error path, where the script is stopping #
# anyway and the operator needs to know which table is bad.                    #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR, UNIPEPT_TEMP_CONSTANT                                            #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   One error message per failed writer to stderr                              #
#                                                                              #
# Returns:                                                                     #
#   0 if no writer failed, 1 otherwise                                         #
################################################################################
report_failed_writers() {
	local dir
	dir="$(writers_dir)"
	local marker
	local status=0

	[[ -d "$dir" ]] || return 0

	for marker in "$dir"/*.fail
	do
		[[ -e "$marker" ]] || continue
		echo "Error: $(cat "$marker") failed." 1>&2
		status=1
	done

	rm -f "$dir"/*.ok "$dir"/*.fail
	return "$status"
}

################################################################################
# start_writer                                                                 #
#                                                                              #
# Creates a FIFO for a file, prints its path, and runs a command on it in the  #
# background. The command gets the FIFO as $1 and the file as $2. Its exit     #
# status is recorded in the writer marker for wait_for_writers.                #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR, UNIPEPT_TEMP_CONSTANT                                            #
#                                                                              #
# Arguments:                                                                   #
#   $1 - The file the command reads or writes                                  #
#   $2 - What the command does, reported if it fails                           #
#   $3 - The command                                                           #
#                                                                              #
# Outputs:                                                                     #
#   The path to the created FIFO                                               #
################################################################################
start_writer() {
	local pipe
	local marker
	pipe="$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$(uuidgen)-$(basename "$1")"
	marker="$(register_writer "$(basename "$pipe")" "$2")"
	mkfifo "$pipe"
	echo "$pipe"
	{
		if "$3" "$pipe" "$1"
		then
			mv "$marker.running" "$marker.ok"
		else
			mv "$marker.running" "$marker.fail"
		fi
		rm -f "$pipe"
	} > /dev/null &
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
	mkdir -p "$(dirname "$1")"
	start_writer "$1" "writing $1" compress_from_pipe
}

compress_from_pipe() {
	$CMD_LZ4 - < "$1" > "$2" || { rm -f "$2"; return 1; }
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
	start_writer "$1" "reading $1" decompress_to_pipe
}

decompress_to_pipe() {
	local status=0
	$CMD_LZ4CAT "$2" > "$1" || status=$?
	# 141 is SIGPIPE: the reader closed the FIFO before the end of the file.
	[[ "$status" -eq 0 || "$status" -eq 141 ]]
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
	if [ "$#" -gt 0 ] && [ -e "$1" ]; then
		shift
		have "$@"
	else
		[ "$#" -eq 0 ]
	fi
}

################################################################################
# collapse                                                                     #
#                                                                              #
# Read from stdin. Each input line consists of two tab-separated columns       #
# (key, value). This function takes the key and collapses all values together  #
# using a semicolon (;). Only neighbouring lines are collapsed, so the input   #
# has to be sorted by key.                                                     #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Collapsed pairs (key, [value])                                             #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
collapse() {
# shellcheck disable=SC2016
$CMD_AWK '
  BEGIN { FS = "\t" }
  {
   if ($1 == prev) {
     out = out ";" $2
   } else {
     if (NR > 1) print prev "\t" out
     prev = $1
     out = $2
   }
  }
  END {
   if (NR > 0) print prev "\t" out
  }
'
}

################################################################################
# build_binaries                                                               #
#                                                                              #
# Builds the release binaries of the Cargo workspace                           #
# This function ensures that all the required binaries are available for the   #
# database building process.                                                   #
#                                                                              #
# Globals:                                                                     #
#   CURRENT_LOCATION - Directory where the script is currently running         #
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
build_binaries() {
  local packages=()
  local package
  for package in "$@"
  do
    packages+=(-p "$package")
  done
  log "Started building Rust utilities"
  cargo build --release --quiet --manifest-path "$LIB_DIR/../../Cargo.toml" "${packages[@]}"
  log "Finished building Rust utilities"
}
