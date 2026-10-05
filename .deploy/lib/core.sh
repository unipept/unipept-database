# shellcheck shell=bash
#
# What every script in .deploy runs on: logging, stopping, the commands it needs, and the trap that
# reports a command that failed. Sourced through .deploy/lib.sh, never run. The pipelines have their
# own, in pipelines/lib/common.sh: these scripts build no tables, and do not need what that carries.

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
# interrupt still reads as one. Each script arms the trap that answers it.
readonly MAIN_PID=$$

die() {
    echo "Error: $*" 1>&2
    [ "$$" = "$BASHPID" ] || kill -USR1 "$MAIN_PID" 2>/dev/null
    exit 2
}

# The ERR trap of every script here: a command that failed where nothing expected it to. Names the
# script, the command and the line. Not the pipelines' own, which also cleans up what they leave.
errorAndExit() {
    local status=$? line=${BASH_LINENO[0]} command=$BASH_COMMAND

    echo "Error: ${0##*/} stopped: '${command}' failed with exit status ${status} at line ${line}." 1>&2
    exit 2
}

# Stops a flag from swallowing the next flag, or nothing at all, as its value.
need_value() {
    local flag="$1" value="$2"

    { [ -n "$value" ] && [[ "$value" != --* ]]; } || die "${flag} requires a value."
}

# build.sh and clone.sh write what the API serves, so they run as the user the API reads as. Run as
# root, they leave a database owned by root: one the next run as DEPLOY_USER cannot replace, and
# one whose readability check passes only because root reads everything. verify.sh and load.sh
# write nothing there, but both check through that same readability check, so they refuse root
# for that reason alone. prune.sh removes databases, so it runs as the user who owns them.
refuse_root() {
    [ "$(id -u)" -ne 0 ] \
        || die "do not run this as root. Run it as ${DEPLOY_USER}, for example: sudo -iu ${DEPLOY_USER}. Only .deploy/opensearch/install.sh needs root."
}
