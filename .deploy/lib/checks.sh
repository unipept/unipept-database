# shellcheck shell=bash
#
# What has to be true before a script changes anything, one function per check, for the routines in
# build.sh, switch.sh, clone.sh, load.sh and distribute.sh that check first. A check prints nothing
# when all is well; otherwise it prints what is wrong as `FAIL …` on stderr and returns 1. A check
# either finds a problem or warns, never both. None of them exits or changes anything.
#
# Uses the settings of config.sh and api.sh, verify_database and verify_database_source from
# database.sh, the links of versions.sh, lock_refused and opensearch_lock_usable from locks.sh, and
# the requests of opensearch/lib.sh. The remote checks reach the other host through remote_sh, which
# clone.sh defines, and on, which distribute.sh defines. Sourced through .deploy/lib.sh.

# A size in KiB, as the messages give it.
gib() { echo "$(($1 / 1024 / 1024)) GiB"; }

# The lock the work is swapped in under at its end, which can be opened at all: found before the
# work, hours earlier. What the work is names it in the message.
check_lock_usable() {
    opensearch_lock_usable \
        || { echo "FAIL cannot open the lock ${OPENSEARCH_LOCK} as $(id -un), which ${1} is swapped in under. Make it readable by $(id -un), or set OPENSEARCH_LOCK." 1>&2; return 1; }
}

# A build needs the memory the API and OpenSearch hold.
check_build_api_stopped() {
    ! grep -qsx unipept-api /proc/[0-9]*/comm \
        || { echo "FAIL The Unipept API is running, and holds memory the suffix array needs." 1>&2; return 1; }
}

check_build_opensearch_stopped() {
    ! { command -v systemctl > /dev/null && systemctl is-active --quiet opensearch 2> /dev/null; } \
        || { echo "FAIL OpenSearch is running, and holds memory the suffix array needs." 1>&2; return 1; }
}

# Room on disk for a build sized by the newest database: 1.5 times it. Given that database, its
# size in KiB, and the KiB free.
check_build_disk() {
    local previous=$1 size=$2 free=$3
    [ "$free" -ge "$((size * 3 / 2))" ] \
        || { echo "FAIL $(gib "$free") is free on disk in ${OUTPUT_DIR}, and a build needs 1.5 times the $(gib "$size") of ${previous##*/}: $(gib $((size * 3 / 2)))." 1>&2; return 1; }
}

# And memory: 1.2 times it. Passes where the kernel does not say what is available.
check_build_memory() {
    local previous=$1 size=$2 available
    available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    [ -z "$available" ] || [ "$available" -ge "$((size * 6 / 5))" ] \
        || { echo "FAIL $(gib "$available") of memory is available, and a build needs 1.2 times the $(gib "$size") of ${previous##*/}: $(gib $((size * 6 / 5)))." 1>&2; return 1; }
}

# A database's directory, given it.
check_db_present() {
    [ -d "$1" ] || { echo "FAIL there is no ${1}. Copy it with clone.sh, or build it, first." 1>&2; return 1; }
}

# Every file the API needs, with content, and the version the directory is named after, which
# verify_database reports one by one.
check_db_whole() {
    verify_database "${1}/suffix-array" || { echo "FAIL ${1} is not a database the API can serve (above)." 1>&2; return 1; }
}

# The table load.sh feeds to OpenSearch. Outside the index, so not one verify_database checks.
check_db_table() {
    [ -s "${1}/tables/uniprot_entries.tsv.lz4" ] || { echo "FAIL ${1} has no tables/uniprot_entries.tsv.lz4" 1>&2; return 1; }
}

# The API's deploy.sh, with the stop and start a switch needs.
check_api_stop_start() {
    local usage_text
    [ -x "$API_DEPLOY" ] || { echo "FAIL there is no API here: ${API_DEPLOY} is missing. unipept-api's install puts it there." 1>&2; return 1; }
    usage_text=$("$API_DEPLOY" 2>&1 || true)
    [[ "$usage_text" == *"deploy.sh start"* ]] \
        || { echo "FAIL ${API_DEPLOY} has no stop and start: update unipept-api on this host first." 1>&2; return 1; }
}

# An older API queries uniprot_entries or its alias whatever version its files are: a switch would
# move the files and not the proteins.
check_api_version() {
    api_state "$API_BINARY" || case $? in
        1) echo "FAIL the API installed is $(api_binary_version "$API_BINARY"), older than ${API_VERSIONED_INDEX_SINCE}, and queries no version's own index. Roll out unipept-api ${API_VERSIONED_INDEX_SINCE} or newer first." 1>&2; return 1 ;;
        *) echo "FAIL cannot run ${API_BINARY} --version to learn which API is installed. Set API_BINARY where it is elsewhere." 1>&2; return 1 ;;
    esac
}

# The one deploy.sh rollback would go back to. An older one queries uniprot_entries or its alias,
# which hold the proteins of the version served before any switch: after one, a rollback would pair
# the new version's files with those proteins, and nothing would notice.
check_api_rollback_version() {
    local rollback
    rollback=$(api_rollback_binary)
    [ ! -e "$rollback" ] || api_state "$rollback" \
        || { echo "FAIL deploy.sh rollback would go back to ${rollback}, which is not ${API_VERSIONED_INDEX_SINCE} or newer, and after a switch would serve this version's files with another's proteins. Remove it, as $(id -un), to give up rolling back past ${API_VERSIONED_INDEX_SINCE}: rm ${rollback}" 1>&2; return 1; }
}

# The API's own check of a database's files, the memory for them and the index of its proteins.
check_api_accepts() {
    "$API_DEPLOY" check --index "${1}/suffix-array" > /dev/null \
        || { echo "FAIL the API's own check refuses ${1}/suffix-array (above)." 1>&2; return 1; }
}

check_links_follows_current() {
    api_follows_current \
        || { echo "FAIL INDEX_LOCATION in ${API_ENV_FILE} is '$(api_index_location)', so the API would not follow the switch. Set it to $(current_link)/suffix-array." 1>&2; return 1; }
}

# The links are moved where nothing can go back if moving them fails.
check_links_movable() {
    [ -w "$OUTPUT_DIR" ] || { echo "FAIL ${OUTPUT_DIR} is not writable by $(id -un), so $(current_link) cannot be moved." 1>&2; return 1; }
}

check_links_previous() {
    local previous
    previous=$(previous_link)
    [ ! -e "$previous" ] || [ -L "$previous" ] \
        || { echo "FAIL ${previous} is there and is not a link, so it cannot point at the version this host leaves." 1>&2; return 1; }
}

check_sudo_opensearch() {
    { sudo -n -l systemctl stop opensearch && sudo -n -l systemctl start opensearch; } > /dev/null 2>&1 \
        || { echo "FAIL ${DEPLOY_USER} may not stop and start OpenSearch through sudo. Run .deploy/opensearch/install.sh again, as root." 1>&2; return 1; }
}

# OpenSearch answers, without which what is in it is not known. Given the index the caller wanted to
# know about.
check_opensearch_answers() {
    opensearch_answers || { echo "FAIL OpenSearch does not answer at ${OPENSEARCH_URL}, so whether ${1} is there is unknown." 1>&2; return 1; }
}

# The index of the version a switch leaves, which going back after a failed start needs as it is.
check_index_to_go_back_to() {
    { [ "$(index_status "$1")" = open ] && is_complete "$1"; } \
        || { echo "FAIL ${1}, of the version this host serves, is not open and loaded to the end, so a switch that fails could not go back to it. Run migrate.sh, or load it again, first." 1>&2; return 1; }
}

# An index, given it, its version and what index_status says of it: nothing for one not there.
check_index_present() {
    [ -n "$3" ] || { echo "FAIL ${1} is not in OpenSearch. Load it with load.sh --uniprot-version ${2}." 1>&2; return 1; }
}

check_index_complete() {
    is_complete "$1" || { echo "FAIL ${1} was not loaded to the end. Continue its load with --skip, or load it again." 1>&2; return 1; }
}

# A database on another host, before anything is copied: its directory, then the same checks the
# copy gets afterwards, run there. The functions and the lists they read are sent along, so both
# sides check against this checkout's contract.
check_remote_db_present() {
    remote_sh "[ -d '${1}' ]" || { echo "FAIL the remote host has no ${1}" 1>&2; return 1; }
}

check_remote_db_whole() {
    remote_sh bash -s << REMOTE || { echo "FAIL the database on ${REMOTE_ADDRESS} is missing files the API needs, or is not the version it is named after." 1>&2; return 1; }
$(verify_database_source)
status=0
verify_database '${1}/suffix-array' || status=1
[ -s '${1}/tables/uniprot_entries.tsv.lz4' ] || { echo "FAIL tables/uniprot_entries.tsv.lz4 is missing" 1>&2; status=1; }
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

# A server distribute.sh puts a version on, given its name, host and install root: it answers, and
# has the scripts installed.
check_server_scripts() {
    on "$2" "$3" test -x bin/verify.sh -a -x bin/clone.sh -a -x bin/load.sh 2> /dev/null \
        || { echo "FAIL ${1} cannot be reached, or has no scripts installed in ${3}." 1>&2; return 1; }
}

# And can clone the version from the source, given the arguments clone.sh takes for it.
check_server_can_clone() {
    local name=$1 host=$2 root=$3
    shift 3
    on "$host" "$root" bin/clone.sh --check "$@" > /dev/null 2>&1 \
        || { echo "FAIL ${name} cannot clone ${UNIPROT_VERSION} from ${SOURCE}; run clone.sh --check there to see why." 1>&2; return 1; }
}
