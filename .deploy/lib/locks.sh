# shellcheck shell=bash
#
# The locks that keep the scripts on one host from working on the same thing at once. Sourced
# through .deploy/lib.sh, after config.sh, which sets OPENSEARCH_LOCK.

# Loads and switches exclude each other: a switch stops OpenSearch, which breaks a load running then.
# A load takes OPENSEARCH_LOCK shared, so loads of different versions still run side by side, and a
# switch takes it exclusively, from its checks to its end. On file descriptor 9, held until the
# script exits. Fails, rather than waits: 1 where the other holds it, 2 where the lock cannot be
# opened at all, which says so.
take_opensearch_lock() {
    { exec 9>> "$OPENSEARCH_LOCK"; } 2> /dev/null || {
        echo "Error: cannot open the lock ${OPENSEARCH_LOCK} as $(id -un)." 1>&2
        return 2
    }
    if [ -n "${2:-}" ]; then
        # Waiting, up to the seconds given, where giving up would throw away work already done.
        flock -w "$2" "$1" 9
    else
        flock -n "$1" 9
    fi
}

# Whether this user can take OPENSEARCH_LOCK at all, for a check made before the work that needs it.
opensearch_lock_usable() {
    ( exec 9>> "$OPENSEARCH_LOCK" ) 2> /dev/null
}

# Loads of different versions run side by side, but two of the same version would drop the index
# the other fills, and the first to finish would mark what the other left as whole; and a build or a
# clone replacing its files would pull the table from under a load of it. One lock per version,
# beside OPENSEARCH_LOCK, on file descriptor 8. Fails with 1 where another holds it, 2 where it
# cannot be opened, which it says.
take_load_lock() {
    local lock
    lock="$(dirname "$OPENSEARCH_LOCK")/unipept-load-${1}.lock"
    { exec 8>> "$lock"; } 2> /dev/null || {
        echo "Error: cannot open the lock ${lock} as $(id -un)." 1>&2
        return 2
    }
    flock -n -x 8
}

# What a script that could not take OPENSEARCH_LOCK says, by why: 1 another holds it, anything else
# it could not be opened.
lock_refused() {
    case $1 in
        1) echo "a load, a switch, a prune or migrate.sh is running on this host; wait for it to finish." ;;
        *) echo "without the lock, a load, a switch or a prune could run at the same time. Make ${OPENSEARCH_LOCK} writable for $(id -un), or set OPENSEARCH_LOCK." ;;
    esac
}
