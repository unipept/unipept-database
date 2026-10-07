# shellcheck shell=bash
#
# What has to be true before a script changes anything, one function per check, for the preflight
# routines of build.sh, switch.sh, clone.sh, distribute.sh and load.sh, and for verify.sh. A check
# prints nothing when all is well; otherwise it prints each thing that is wrong as `FAIL …` on
# stderr, the form verify.sh reports in, and returns 1. A warning, as check_index_optional_files
# gives, prints `WARN …` and returns 0: it changes nothing about what a script does. None of them
# exits, and none changes anything but check_lock_usable, which makes the lock file where there is
# none, as every script that takes the lock does.
#
# Uses the settings of config.sh, the lists of database.sh, the links of versions.sh,
# opensearch_lock_usable and lock_refused from locks.sh, what api.sh knows of the API, and the
# requests of opensearch/lib.sh. The checks of another host need a way to reach it, which only
# clone.sh and distribute.sh define; they say so where they are. Sourced through .deploy/lib.sh.

# A size in KiB, as the messages give it.
gib() { echo "$(($1 / 1024 / 1024)) GiB"; }

# A directory's size in KiB, as its files are long rather than as the disk packs them. Fails, with
# du's own reason, on a directory it cannot measure whole.
size_kib() {
    local line
    line=$(du -sk --apparent-size -- "$1") || return 1
    echo "${line%%[[:space:]]*}"
}

# The host a build runs on. A build needs the memory the API and OpenSearch hold, and room on disk
# and in memory sized by the newest database: 1.5 times it on disk, for the new database beside the
# old one and the files the build works through, and 1.2 times it in memory.

check_api_stopped() {
    ! grep -qsx unipept-api /proc/[0-9]*/comm \
        || { echo "FAIL The Unipept API is running, and holds memory the suffix array needs." 1>&2; return 1; }
}

check_opensearch_stopped() {
    ! { command -v systemctl > /dev/null && systemctl is-active --quiet opensearch 2> /dev/null; } \
        || { echo "FAIL OpenSearch is running, and holds memory the suffix array needs." 1>&2; return 1; }
}

# Given the newest database, its size in KiB, and the staging directory a build works in. What the
# last build left there is removed before the next one starts, so it counts as free; left out when
# it cannot be measured, which only makes the check stricter.
check_disk_room() {
    local previous=$1 size=$2 staging_dir=$3 staging=0 available free
    [ ! -d "$staging_dir" ] || staging=$(size_kib "$staging_dir" 2> /dev/null) || staging=0
    available=$(df -Pk "$OUTPUT_DIR" | awk 'NR == 2 { print $4 }')
    [ -n "$available" ] || { echo "FAIL cannot tell how much is free on disk in ${OUTPUT_DIR}: df says nothing of it." 1>&2; return 1; }
    free=$((available + staging))
    [ "$free" -ge "$((size * 3 / 2))" ] \
        || { echo "FAIL $(gib "$free") is free on disk in ${OUTPUT_DIR}, and a build needs 1.5 times the $(gib "$size") of ${previous##*/}: $(gib $((size * 3 / 2)))." 1>&2; return 1; }
}

# Passes where the kernel does not say what is available.
check_memory_free() {
    local previous=$1 size=$2 available
    available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    [ -z "$available" ] || [ "$available" -ge "$((size * 6 / 5))" ] \
        || { echo "FAIL $(gib "$available") of memory is available, and a build needs 1.2 times the $(gib "$size") of ${previous##*/}: $(gib $((size * 6 / 5)))." 1>&2; return 1; }
}

# The lock a build or a clone is swapped in under at its end, which can be opened at all: found
# before the work, hours earlier. Given what the work is, for the message.
check_lock_usable() {
    opensearch_lock_usable \
        || { echo "FAIL ${1} is swapped in under ${OPENSEARCH_LOCK} at its end, which $(id -un) cannot open: $(lock_refused 2)" 1>&2; return 1; }
}

# A database: its directory, given it, and in it the files the API needs, with the right .version,
# and the table load.sh reads.

check_db_present() {
    [ -d "$1" ] || { echo "FAIL there is no ${1}. Copy it with clone.sh, or build it, first." 1>&2; return 1; }
}

# Every index file that is missing, empty or unreadable, rather than the first, in the directory the
# API is pointed at. An empty file passes the API's own readable check and fails the service later,
# so the test here is on content.
#
# Readable means readable by whoever runs this. Root reads everything, so as root an unreadable file
# would pass: every script that calls this refuses root first.
check_index_files() {
    local index="$1" relative missing=0 hidden=''

    [ -d "$index" ] || { echo "FAIL ${index} is not a directory" 1>&2; return 1; }

    # A directory that cannot be entered hides the files in it, which would read as missing and send
    # the operator to rebuild rather than to fix a permission. It is named once, and what is in it is
    # not reported again.
    if [ ! -r "$index" ] || [ ! -x "$index" ]; then
        echo "FAIL ${index} is not readable" 1>&2
        return 1
    fi
    if [ -d "${index}/datastore" ] && { [ ! -r "${index}/datastore" ] || [ ! -x "${index}/datastore" ]; }; then
        echo "FAIL datastore/ is not readable" 1>&2
        missing=1
        hidden=datastore/
    fi

    for relative in "${INDEX_FILES[@]}"; do
        if [ -n "$hidden" ] && [[ "$relative" == "$hidden"* ]]; then
            continue
        elif [ ! -e "${index}/${relative}" ]; then
            echo "FAIL ${relative} is missing" 1>&2
            missing=1
        elif [ ! -r "${index}/${relative}" ]; then
            echo "FAIL ${relative} is not readable" 1>&2
            missing=1
        elif [ ! -s "${index}/${relative}" ]; then
            echo "FAIL ${relative} is empty" 1>&2
            missing=1
        fi
    done
    return "$missing"
}

# A warning: the files the API opens when they are there and runs without, slower. Only in a
# directory it can look in: check_index_files reports one it cannot.
check_index_optional_files() {
    local index="$1" relative

    { [ -d "$index" ] && [ -r "$index" ] && [ -x "$index" ]; } || return 0
    for relative in "${OPTIONAL_INDEX_FILES[@]}"; do
        [ -s "${index}/${relative}" ] \
            || echo "WARN ${relative} is missing; the API runs without it and searches are slower" 1>&2
    done
    return 0
}

# The directory a build writes is named after the version inside it. A pair that disagrees means one
# of the two came from somewhere else.
check_index_version() {
    local index="$1" named version

    named=$(database_version_of "$index") || return 0
    # Missing, empty or unreadable is check_index_files's to report, and a version read from a file
    # that cannot be read would only add a second, misleading failure.
    { [ -s "${index}/.version" ] && [ -r "${index}/.version" ]; } || return 0

    version=$(read_version "${index}/.version")
    [ "$named" = "$version" ] || { echo "FAIL the directory says ${named} and .version says ${version}" 1>&2; return 1; }
}

# The whole contract the directory the API is pointed at is held to: its files, with the warning of
# what it could do without, and its version, each reporting every failure. verify.sh's check.
check_index_whole() {
    local status=0
    check_index_files "$1" || status=1
    check_index_optional_files "$1"
    check_index_version "$1" || status=1
    return "$status"
}

# The same of a database, given its directory, before the API is pointed at it.
check_db_whole() {
    check_index_whole "${1}/suffix-array" || { echo "FAIL ${1} is not a database the API can serve (above)." 1>&2; return 1; }
}

# The table load.sh feeds to OpenSearch. Outside the index, so not one check_index_files checks.
check_db_table() {
    [ -s "${1}/${ENTRIES_TABLE}" ] || { echo "FAIL ${1} has no ${ENTRIES_TABLE}" 1>&2; return 1; }
}

# The API on this host, as its install lays it out.

# Its deploy.sh, answering status in the format these scripts read: what a switch asks it, and the
# stop and start it runs. Prints that status, for the checks that read it.
check_api_status() {
    api_status || { echo "FAIL ${API_DEPLOY} status does not answer as these scripts read it (above)." 1>&2; return 1; }
}

# The API's own check of a database's files, the memory for them and the index of its proteins.
check_api_accepts() {
    "$API_DEPLOY" check --index "${1}/suffix-array" > /dev/null \
        || { echo "FAIL the API's own check refuses ${1}/suffix-array (above)." 1>&2; return 1; }
}

# The links in OUTPUT_DIR that say which version this host serves.

# INDEX_LOCATION, as the API's status gives it, goes through `current`, so the API follows a switch.
check_links_follows_current() {
    api_follows_current "$1" \
        || { echo "FAIL INDEX_LOCATION in the API's settings is '${1}', so the API would not follow the switch. Set it to $(current_link)/suffix-array." 1>&2; return 1; }
}

# OUTPUT_DIR is writable, so `current` can be moved: a switch moves it with the API and OpenSearch
# stopped, where a failure would leave the host down.
check_links_movable() {
    [ -w "$OUTPUT_DIR" ] || { echo "FAIL ${OUTPUT_DIR} is not writable by $(id -un), so $(current_link) cannot be moved." 1>&2; return 1; }
}

# `previous` is a link, or not there, so it can be pointed at the version a switch leaves.
check_links_previous() {
    local previous
    previous=$(previous_link)
    [ ! -e "$previous" ] || [ -L "$previous" ] \
        || { echo "FAIL ${previous} is there and is not a link, so it cannot point at the version this host leaves." 1>&2; return 1; }
}

# OpenSearch on this host, and the index of a version in it.

# The sudo rule server/opensearch/install.sh writes, through which a switch stops and starts
# OpenSearch.
check_sudo_opensearch() {
    { sudo -n -l systemctl stop opensearch && sudo -n -l systemctl start opensearch; } > /dev/null 2>&1 \
        || { echo "FAIL ${DEPLOY_USER} may not stop and start OpenSearch through sudo. Run .deploy/server/opensearch/install.sh again, as root." 1>&2; return 1; }
}

# Given the index the caller wants to know about, which is unknown when nothing answers.
check_opensearch_answers() {
    opensearch_answers || { echo "FAIL OpenSearch does not answer at ${OPENSEARCH_URL}, so whether ${1} is there is unknown." 1>&2; return 1; }
}

# Given an index, its version, and what index_status said of it: nothing for one not there.
check_opensearch_index_present() {
    [ -n "$3" ] || { echo "FAIL ${1} is not in OpenSearch. Load it with load.sh --uniprot-version ${2}." 1>&2; return 1; }
}

# An index carries the mark a load leaves once its last row is in. OpenSearch not saying is not a
# "no", and is said apart.
check_opensearch_index_complete() {
    case $(load_state "$1") in
        complete) ;;
        unknown) echo "FAIL OpenSearch did not say whether ${1} is loaded to the end. Try again once it answers." 1>&2; return 1 ;;
        *) echo "FAIL ${1} was not loaded to the end. Continue its load with --skip, or load it again." 1>&2; return 1 ;;
    esac
}

# The index of the version a switch leaves is there and open, as going back after a failed start
# needs it. Given the index and its version.
check_opensearch_index_open() {
    case $(index_status "$1") in
        open) ;;
        '') echo "FAIL ${1}, of the version this host serves, is not in OpenSearch, so a switch that fails could not go back to it. Load it with load.sh --uniprot-version ${2} first." 1>&2; return 1 ;;
        *) echo "FAIL ${1}, of the version this host serves, is not open, so a switch that fails could not go back to it. Open it first: curl -X POST ${OPENSEARCH_URL}/${1}/_open" 1>&2; return 1 ;;
    esac
}

# A database on another host, before anything is copied from it. Run from clone.sh, through its
# remote_sh, with its REMOTE_ADDRESS.

check_remote_db_present() {
    remote_sh "[ -d '${1}' ]" || { echo "FAIL the remote host has no ${1}" 1>&2; return 1; }
}

# The same checks the copy gets afterwards, run there. The functions and the lists they read are sent
# along, so both sides check against this checkout's contract.
check_remote_db_whole() {
    remote_sh bash -s << REMOTE || { echo "FAIL the database on ${REMOTE_ADDRESS} cannot be cloned (above)." 1>&2; return 1; }
$(declare -p INDEX_FILES OPTIONAL_INDEX_FILES ENTRIES_TABLE)
$(declare -f check_db_whole check_db_table check_index_whole check_index_files check_index_optional_files check_index_version database_version_of read_version)
status=0
check_db_whole '${1}' || status=1
check_db_table '${1}' || status=1
exit "\$status"
REMOTE
}

# The k-mer table is an accelerator the API runs without, so a database built before build.sh wrote
# one has none and is still worth cloning. The remote decides: one the remote has and the copy does
# not is a copy that lost it. test answers 0 or 1; anything else is ssh failing, which says nothing
# about the table. Given the copy and the remote's directory.
check_copy_kept_kmer_table() {
    local copy=$1 remote=$2 has=0
    remote_sh "[ -s '${remote}/suffix-array/kmer_table.bin' ]" || has=$?
    case "$has" in
        0) [ -s "${copy}/suffix-array/kmer_table.bin" ] || { echo "FAIL the remote has a k-mer table and the copy does not" 1>&2; return 1; } ;;
        1) ;;
        *) echo "FAIL could not ask ${REMOTE_ADDRESS} whether it has a k-mer table, so cannot tell whether the copy lost one." 1>&2; return 1 ;;
    esac
}

# A server distribute.sh puts a version on, given its name, host and install root. Run from
# distribute.sh, through its `on`, with its SOURCE, SOURCE_OUTPUT_DIR and UNIPROT_VERSION.

# It answers, and has the scripts installed.
check_server_scripts() {
    on "$2" "$3" test -x bin/verify.sh -a -x bin/clone.sh -a -x bin/load.sh 2> /dev/null \
        || { echo "FAIL ${1} cannot be reached, or has no scripts installed in ${3}; .deploy/server/opensearch/install.sh installs them." 1>&2; return 1; }
}

# And can clone the version from the source, as its own deploy.conf decides.
check_server_can_clone() {
    on "$2" "$3" bin/clone.sh --check --remote-address "$SOURCE" --remote-output-dir "$SOURCE_OUTPUT_DIR" \
        --uniprot-version "$UNIPROT_VERSION" > /dev/null 2>&1 \
        || { echo "FAIL ${1} cannot clone ${UNIPROT_VERSION} from ${SOURCE}; run clone.sh --check there to see why." 1>&2; return 1; }
}
