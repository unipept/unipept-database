# shellcheck shell=bash
#
# What every script in .deploy runs on: logging, stopping, the commands it needs, and the trap that
# reports a command that failed. Needs nothing else. Sourced through .deploy/lib.sh, never run. The
# pipelines have their own, in pipelines/lib/common.sh: these scripts build no tables, and do not
# need what that carries.

# Prints a line on standard output, stamped with the epoch second and the local date and time.
log() { echo "$(date +'[%s (%F %T)]')" "$@"; }

# Stops, saying what to install, where a command a script needs is not there.
checkdep() {
    which "$1" > /dev/null 2>&1 || hash "$1" > /dev/null 2>&1 || {
        echo "This script requires ${2:-$1} to be installed." >&2
        exit 6
    }
}

# The script's own process, captured before any subshell can shadow it. A die inside a command
# substitution only ends that subshell, and the caller then reports the same failure a second time
# through the ERR trap, so die signals the script itself. USR1 rather than TERM, so a real
# interrupt still reads as one.
readonly MAIN_PID=$$
trap 'exit 2' USR1

die() {
    echo "Error: $*" 1>&2
    [ "$$" = "$BASHPID" ] || kill -USR1 "$MAIN_PID" 2>/dev/null
    exit 2
}

# The ERR trap of every script here: a command that failed where nothing expected it to. Names the
# script, the command, and the file and line it is on, which is a part of lib.sh where it failed in
# one. In a subshell, such as a command substitution or a process substitution, it says nothing and
# passes the status on: errtrace runs it there even where the shell that started the subshell
# expects the failure, as in `x=$(...) || return 1`, and a subshell cannot tell. Where that shell
# acts on the status, as an assignment from $(...) does, its own trap reports the failure once, at
# the line that started the subshell. Where it does not, as in `echo "$(...)"`, nothing is reported,
# as set -e alone would not stop there either. Not the pipelines' own, which also cleans up what
# they leave.
errorAndExit() {
    local status=$? line=${BASH_LINENO[0]} file=${BASH_SOURCE[1]} command=$BASH_COMMAND

    [ "$$" = "$BASHPID" ] || exit "$status"
    echo "Error: ${0##*/} stopped: '${command}' failed with exit status ${status} at line ${line} of ${file}." 1>&2
    exit 2
}

# Stops a flag from swallowing the next flag, or nothing at all, as its value.
need_value() {
    local flag="$1" value="$2"

    { [ -n "$value" ] && [[ "$value" != --* ]]; } || die "${flag} requires a value."
}
