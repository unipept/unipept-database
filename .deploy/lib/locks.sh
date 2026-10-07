# shellcheck shell=bash
#
# The locks that keep the scripts on one host from working on the same thing at once: their own, and
# the API's, which a switch holds so no deploy restarts the API under it. Needs nothing else.
# Sourced through .deploy/lib.sh.

# The lock that keeps loads apart from switches, prunes and installs. One per host, as the OpenSearch it guards is,
# whatever OUTPUT_DIR a run is given; /run/lock is there for every user to take one in. Fixed, so
# every script that takes it names the same file.
readonly OPENSEARCH_LOCK=/run/lock/unipept-opensearch.lock

# Seconds a build or a clone waits for that lock once its work is done, rather than throw the work
# away: a switch holds it while OpenSearch starts, which takes minutes.
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly LOCK_WAIT=3600

# What a script says where a lock file cannot be opened, which is a permission to fix.
cannot_open_lock() {
    echo "Error: cannot open the lock ${1} as $(id -un)." 1>&2
}

# Opens a lock file for flock on a file descriptor of this shell, made first where no one has made
# it. For reading, which is all flock needs: /run/lock is sticky, so opening another user's file
# there for writing is refused even to root, which is how server/install.sh takes these.
# On descriptor 7, 8 or 9, the three these locks use.
# Fails, saying so, where it cannot.
open_lock() {
    local fd=$1 lock=$2

    {
        # Made where missing, 0644 whoever makes it: root's umask may be 077, and the deploy user
        # could then not read a lock an install left behind. And there regardless where another
        # account made it between the test and the open: that open to create is refused, in a
        # sticky directory, though the file is there to take.
        { [ -e "$lock" ] || (umask 022 && : >> "$lock") || [ -e "$lock" ]; } &&
            case $fd in
                7) exec 7< "$lock" ;;
                8) exec 8< "$lock" ;;
                9) exec 9< "$lock" ;;
            esac
    } 2> /dev/null || { cannot_open_lock "$lock"; return 2; }
}

# Loads and switches exclude each other: a switch stops OpenSearch, which breaks a load running then.
# A load takes OPENSEARCH_LOCK shared, so loads of different versions still run side by side, and a
# switch, a prune or an install takes it exclusively, from its checks to its end. On file descriptor
# 9, held until the script exits. Fails, rather than waits: 1 where the other holds it, 2 where the
# lock cannot be opened at all, which says so.
#
# A caller that holds it hands it down by leaving descriptor 9 open on it, as server/install.sh does
# for opensearch/install.sh, and this then takes that descriptor rather than open the file again:
# flock ties a lock to the open file, not to the process, so a second open would conflict with the
# caller's own lock. On the descriptor handed down, flock succeeds where the caller holds the lock,
# and takes it where nobody does, for as long as the caller keeps the descriptor open. The two ask in
# the same mode: on a shared open file, flock in another one changes the caller's lock as well.
take_opensearch_lock() {
    [ /dev/fd/9 -ef "$OPENSEARCH_LOCK" ] || open_lock 9 "$OPENSEARCH_LOCK" || return 2
    if [ -n "${2:-}" ]; then
        # Waiting, up to the seconds given, where giving up would throw away work already done.
        flock -w "$2" "$1" 9
    else
        flock -n "$1" 9
    fi
}

# Whether this user can take OPENSEARCH_LOCK at all, for a check made before the work that needs it.
opensearch_lock_usable() {
    ( open_lock 9 "$OPENSEARCH_LOCK" ) 2> /dev/null
}

# Loads of different versions run side by side, but two of the same version would drop the index
# the other fills, and the first to finish would mark what the other left as whole; and a build or a
# clone replacing its files would pull the table from under a load of it. One lock per version,
# beside OPENSEARCH_LOCK, on file descriptor 8. Fails with 1 where another holds it, 2 where it
# cannot be opened, which it says.
take_load_lock() {
    local lock
    lock="$(dirname "$OPENSEARCH_LOCK")/unipept-load-${1}.lock"
    open_lock 8 "$lock" || return 2
    flock -n -x 8
}

# What a script that could not take OPENSEARCH_LOCK says, by why: 1 another holds it, anything else
# it could not be opened.
lock_refused() {
    case $1 in
        1) echo "a load, a switch, a prune, an install, or a build or a clone putting a database in place, is running on this host; wait for it to finish." ;;
        *) echo "without the lock, a load, a switch or a prune could run at the same time. Make ${OPENSEARCH_LOCK} readable by $(id -un)." ;;
    esac
}

# The API's own lock, at the path its deploy.sh status names, on file descriptor 7, held until the
# script exits. Its deploy, rollback, stop and start take it too, so while a switch holds it no
# deploy restarts the API on the version being left; the deploy.sh stop and start the switch runs
# find it on descriptor 7, which they inherit, and take it through that rather than being refused.
# Fails, rather than waits: 1 where another holds it, 2 where it cannot be opened, which it says.
take_api_lock() {
    open_lock 7 "$1" || return 2
    flock -n 7
}

# What a script that could not take the API lock says, by why.
api_lock_refused() {
    case $1 in
        1) echo "a deploy, rollback, start or stop, an install, or a change to the index this host serves, holds ${2}; wait for it to finish" ;;
        *) echo "without the API's lock, a deploy could restart the API during the switch. Make ${2} readable by $(id -un)." ;;
    esac
}
