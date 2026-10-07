#!/usr/bin/env bash
#
# The parts of .deploy/lib.sh, function by function, for what the scripts that use them seldom or
# never reach: core.sh's cases, which every repository that shares it runs, and then this
# repository's own: what the API's deploy.sh status says, paths that resolve to nothing, and every
# check in checks.sh, passing and failing. The rest each part does is checked through the scripts,
# in the verify, deploy and opensearch suites. Needs no container and no network.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "${HERE}/../../.deploy" && pwd)/lib.sh"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# What lib/core.sh does, the same cases as every repository that shares it.
# shellcheck source=core-cases.sh
source "${HERE}/core-cases.sh"

# Runs code in a bash of its own that has sourced lib.sh, as a script does, and exits with the
# status of that code. Its own process, since die signals the process that sourced lib.sh. The code
# runs where a failure is expected, as in an `if`, so a function that returns non-zero says so here
# rather than tripping the error trap.
in_lib() {
    # shellcheck disable=SC2016 # expanded by the bash it starts
    bash -c 'source "$1"; shift; eval "$1" || exit $?' in_lib "$LIB" "$1"
}


section "api.sh: api_status"

# The API's deploy.sh, a stand-in answering status from a file each case writes.
API="$(make_api_deploy "${TEMP_DIR}/deploy.sh")"

api_status_lines /srv/index uniprot_entries-2026-03 > "${API}.status"
check "what status says, in the format these scripts read" \
    "$(in_lib "API_DEPLOY='${API}'; api_status" | sed -n 's/^opensearch_index=//p')" "uniprot_entries-2026-03"

sed 's/^status_format=1$/status_format=2/' "${API}.status" > "${TEMP_DIR}/format-2"
cp "${TEMP_DIR}/format-2" "${API}.status"
output=$(in_lib "API_DEPLOY='${API}'; api_status" 2>&1)
check "a format these scripts do not read is refused" "$?" "1"
check_true "saying which" grep -qF "answers in format '2', and these scripts read 1" <<< "$output"

output=$(in_lib "API_DEPLOY='${TEMP_DIR}/no-deploy.sh'; api_status" 2>&1)
check "a host without deploy.sh has no status" "$?" "1"
check_true "and runs no API" grep -qF "there is no API here: ${TEMP_DIR}/no-deploy.sh is missing" <<< "$output"

output=$(in_lib "API_DEPLOY='$(make_stub "${TEMP_DIR}/failing-deploy.sh" 'echo "Error: run this as unipept" 1>&2; exit 2')'; api_status" 2>&1)
check "a deploy.sh whose status fails says nothing" "$?" "1"
check_true "and why, after its own message" grep -qF "status did not answer (above)" <<< "$output"


section "api.sh: api_follows_current"

mkdir -p "${TEMP_DIR}/data"
in_lib "OUTPUT_DIR='${TEMP_DIR}/data'; api_follows_current '${TEMP_DIR}/data/current/suffix-array/'"
check "an INDEX_LOCATION through current in OUTPUT_DIR follows it" "$?" "0"

ln -s "${TEMP_DIR}/data" "${TEMP_DIR}/data-link"
in_lib "OUTPUT_DIR='${TEMP_DIR}/data-link/'; api_follows_current '${TEMP_DIR}/data/current/suffix-array/'"
check "as does an OUTPUT_DIR that is a link to that directory" "$?" "0"

mkdir -p "${TEMP_DIR}/elsewhere"
in_lib "OUTPUT_DIR='${TEMP_DIR}/elsewhere'; api_follows_current '${TEMP_DIR}/data/current/suffix-array/'"
check "a current in another directory is not followed" "$?" "1"

in_lib "OUTPUT_DIR='${TEMP_DIR}/not/there'; api_follows_current '${TEMP_DIR}/data/current/suffix-array/'"
check "nor is an OUTPUT_DIR that resolves to nothing" "$?" "1"

in_lib "OUTPUT_DIR='${TEMP_DIR}/not/there'; api_follows_current '${TEMP_DIR}/gone/away/current/suffix-array'"
check "two paths that resolve to nothing are not the same one" "$?" "1"

in_lib "OUTPUT_DIR='${TEMP_DIR}/data'; api_follows_current '${TEMP_DIR}/data/uniprot-2026-03/suffix-array'"
check "an INDEX_LOCATION that names a version's directory itself does not follow current" "$?" "1"

in_lib "OUTPUT_DIR='${TEMP_DIR}/data'; api_follows_current ''"
check "nor does none" "$?" "1"


section "api.sh: served_versions and is_served"

mkdir -p "${TEMP_DIR}/served/uniprot-2026-03"
ln -s uniprot-2026-03 "${TEMP_DIR}/served/current"
api_status_lines "${TEMP_DIR}/served/uniprot-2026-02/suffix-array" uniprot_entries-2026-02 > "${API}.status"
SERVED_HOST="OUTPUT_DIR='${TEMP_DIR}/served' API_DEPLOY='${API}'"

check "what current points at, and what the API reads, by its directory and its index" \
    "$(in_lib "${SERVED_HOST}; served_versions" | tr '\n' ' ')" "2026-03 2026-02 2026-02 "
in_lib "${SERVED_HOST}; is_served 2026-03"
check "what current points at is served" "$?" "0"
in_lib "${SERVED_HOST}; is_served 2026-02"
check "and so is the version the API queries" "$?" "0"
in_lib "${SERVED_HOST}; is_served 2026-04"
check "another version is not" "$?" "1"

api_status_lines "${TEMP_DIR}/served/uniprot-2026-02/suffix-array" - > "${API}.status"
check "where the API's files have no .version, the version of the directory it reads" \
    "$(in_lib "${SERVED_HOST}; served_versions" | tr '\n' ' ')" "2026-03 2026-02 "
api_status_lines "${TEMP_DIR}/served/uniprot-2026-02.bak/suffix-array" - > "${API}.status"
check "but not a directory whose name is no version" \
    "$(in_lib "${SERVED_HOST}; served_versions" | tr '\n' ' ')" "2026-03 "
api_status_lines "${TEMP_DIR}/served/current/suffix-array" uniprot_entries-2026-02 > "${API}.status"
check "and through current, the version of the index it queries" \
    "$(in_lib "${SERVED_HOST}; served_versions" | tr '\n' ' ')" "2026-03 2026-02 "

check "a host without an API serves what current points at" \
    "$(in_lib "OUTPUT_DIR='${TEMP_DIR}/served' API_DEPLOY='${TEMP_DIR}/no-deploy.sh'; served_versions" | tr '\n' ' ')" "2026-03 "

cp "${TEMP_DIR}/format-2" "${API}.status"
output=$(in_lib "${SERVED_HOST}; is_served 2026-04" 2>&1)
check "an API that does not say what it serves stops the script" "$?" "2"
check_true "saying so" grep -qF "does not say which version this host serves" <<< "$output"


section "checks.sh: each check, passing and failing"

# One check, run as a script runs it, in a setting made bad for it: it fails, saying what is wrong.
# Each setting is the code before the check, with stand-ins for what a check would otherwise ask of
# OpenSearch, the API or another host.
fails_saying() {
    local name=$1 setting=$2 says=$3 output
    output=$(in_lib "$setting" 2>&1)
    check "${name} fails" "$?" "1"
    check_true "and says so" grep -qF -- "$says" <<< "$(grep '^FAIL ' <<< "$output")"
}

# And passes in a good one.
both_ways() {
    in_lib "$2" > /dev/null 2>&1
    check "${1} passes" "$?" "0"
    fails_saying "$1" "$3" "$4"
}

DB="$(dirname "$(make_database "${TEMP_DIR}/checks/data" 2026-03)")"
EMPTY="${TEMP_DIR}/checks/empty"
mkdir -p "$EMPTY"

both_ways check_db_present "check_db_present '${DB}'" "check_db_present '${TEMP_DIR}/checks/gone'" "there is no ${TEMP_DIR}/checks/gone"
both_ways check_index_files "check_index_files '${DB}/suffix-array'" "check_index_files '${EMPTY}'" "sa.bin is missing"
mkdir -p "${TEMP_DIR}/checks/other/uniprot-2026-04"
cp -R "${DB}/suffix-array" "${TEMP_DIR}/checks/other/uniprot-2026-04/"
output=$(in_lib "check_index_optional_files '${DB}/suffix-array'" 2>&1)
check "check_index_optional_files passes with every optional file" "$?:${output}" "0:"
mkdir -p "${TEMP_DIR}/checks/no-kmer"
output=$(in_lib "check_index_optional_files '${TEMP_DIR}/checks/no-kmer'" 2>&1)
check "and passes without one, a warning" "$?" "0"
check_true "which it gives" grep -qF "WARN kmer_table.bin is missing" <<< "$output"
both_ways check_index_version "check_index_version '${DB}/suffix-array'" "check_index_version '${TEMP_DIR}/checks/other/uniprot-2026-04/suffix-array'" \
    "the directory says 2026-04 and .version says 2026-03"
both_ways check_db_whole "check_db_whole '${DB}'" "check_db_whole '${EMPTY}'" "${EMPTY} is not a database the API can serve"
both_ways check_db_table "check_db_table '${DB}'" "check_db_table '${EMPTY}'" "${EMPTY} has no tables/uniprot_entries.tsv.lz4"

# Through a stand-in for whether the lock opens: its path is fixed, in /run/lock, which the scripts'
# own suites take it in.
both_ways check_lock_usable \
    "opensearch_lock_usable() { return 0; }; check_lock_usable 'the work'" \
    "opensearch_lock_usable() { return 1; }; check_lock_usable 'the work'" \
    "the work is swapped in under /run/lock/unipept-opensearch.lock at its end"
both_ways check_disk_room \
    "OUTPUT_DIR='${TEMP_DIR}'; check_disk_room '${DB}' 1 '${TEMP_DIR}/none'" \
    "OUTPUT_DIR='${TEMP_DIR}'; check_disk_room '${DB}' $((1024 * 1024 * 1024 * 1024)) '${TEMP_DIR}/none'" \
    "is free on disk"
# Stand-ins for systemctl and sudo, on a PATH of their own.
mkdir -p "${TEMP_DIR}/checks/bin"
make_stub "${TEMP_DIR}/checks/bin/systemctl" "[ -e '${TEMP_DIR}/checks/opensearch-active' ]" > /dev/null
make_stub "${TEMP_DIR}/checks/bin/sudo" "[ -e '${TEMP_DIR}/checks/sudo-allowed' ]" > /dev/null
STAND_INS="PATH='${TEMP_DIR}/checks/bin':\$PATH"
both_ways check_opensearch_stopped \
    "${STAND_INS}; check_opensearch_stopped" \
    "${STAND_INS}; touch '${TEMP_DIR}/checks/opensearch-active'; check_opensearch_stopped" \
    "OpenSearch is running"
rm -f "${TEMP_DIR}/checks/opensearch-active"
both_ways check_sudo_opensearch \
    "${STAND_INS}; touch '${TEMP_DIR}/checks/sudo-allowed'; check_sudo_opensearch" \
    "${STAND_INS}; rm -f '${TEMP_DIR}/checks/sudo-allowed'; check_sudo_opensearch" \
    "may not stop and start OpenSearch through sudo"

# What the kernel says of memory and processes, where it says it: /proc is Linux's.
if [ -r /proc/meminfo ]; then
    available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    both_ways check_memory_free "check_memory_free '${DB}' 1" "check_memory_free '${DB}' $((available * 2))" "of memory is available"
    # A script named unipept-api, which the kernel names the process after while it waits on its
    # sleep, waited for until it does.
    make_stub "${TEMP_DIR}/checks/unipept-api" 'sleep 30' > /dev/null
    in_lib "check_api_stopped" > /dev/null 2>&1
    check "check_api_stopped passes" "$?" "0"
    "${TEMP_DIR}/checks/unipept-api" &
    running=$!
    for _ in $(seq 50); do grep -qsx unipept-api "/proc/${running}/comm" && break; sleep 0.1; done
    fails_saying check_api_stopped check_api_stopped "The Unipept API is running"
    kill "$running" 2> /dev/null
    wait "$running" 2> /dev/null
fi

# The API, as its install lays it out: a deploy.sh that answers status, and its own check.
api_status_lines /srv/index uniprot_entries-2026-03 > "${API}.status"
both_ways check_api_status "API_DEPLOY='${API}'; check_api_status" "API_DEPLOY='${TEMP_DIR}/no-deploy.sh'; check_api_status" \
    "${TEMP_DIR}/no-deploy.sh status does not answer as these scripts read it"
cp "${TEMP_DIR}/format-2" "${TEMP_DIR}/format-2-deploy.sh.status"
fails_saying "check_api_status, on a status of another format," \
    "API_DEPLOY='$(make_api_deploy "${TEMP_DIR}/format-2-deploy.sh")'; check_api_status" \
    "${TEMP_DIR}/format-2-deploy.sh status does not answer as these scripts read it"
both_ways check_api_accepts "API_DEPLOY='${API}'; check_api_accepts '${DB}'" \
    "API_DEPLOY='$(make_stub "${TEMP_DIR}/refusing-deploy.sh" 'exit 1')'; check_api_accepts '${DB}'" \
    "the API's own check refuses ${DB}/suffix-array"

# The links of a host whose API follows current, and of one whose does not.
LINKS="${TEMP_DIR}/checks/links"
mkdir -p "${LINKS}/data/uniprot-2026-03"
ln -sfn uniprot-2026-03 "${LINKS}/data/current"
both_ways check_links_follows_current \
    "OUTPUT_DIR='${LINKS}/data'; check_links_follows_current '${LINKS}/data/current/suffix-array'" \
    "OUTPUT_DIR='${LINKS}/data'; check_links_follows_current '${LINKS}/data/uniprot-2026-03/suffix-array'" \
    "INDEX_LOCATION in the API's settings is '${LINKS}/data/uniprot-2026-03/suffix-array', so the API would not follow the switch"
mkdir -p "${LINKS}/locked" && chmod 555 "${LINKS}/locked"
both_ways check_links_movable "OUTPUT_DIR='${LINKS}/data'; check_links_movable" "OUTPUT_DIR='${LINKS}/locked'; check_links_movable" "${LINKS}/locked is not writable"
chmod 755 "${LINKS}/locked"
mkdir -p "${LINKS}/odd/previous"
both_ways check_links_previous "OUTPUT_DIR='${LINKS}/data'; check_links_previous" "OUTPUT_DIR='${LINKS}/odd'; check_links_previous" "${LINKS}/odd/previous is there and is not a link"

# OpenSearch, through stand-ins for what it would answer.
both_ways check_opensearch_answers \
    "opensearch_answers() { return 0; }; check_opensearch_answers uniprot_entries-2026-03" \
    "opensearch_answers() { return 1; }; check_opensearch_answers uniprot_entries-2026-03" \
    "OpenSearch does not answer at"
both_ways check_opensearch_index_present \
    "check_opensearch_index_present uniprot_entries-2026-03 2026-03 open" \
    "check_opensearch_index_present uniprot_entries-2026-03 2026-03 ''" \
    "uniprot_entries-2026-03 is not in OpenSearch. Load it with load.sh --uniprot-version 2026-03"
both_ways check_opensearch_index_complete \
    "load_state() { echo complete; }; check_opensearch_index_complete uniprot_entries-2026-03" \
    "load_state() { echo incomplete; }; check_opensearch_index_complete uniprot_entries-2026-03" \
    "uniprot_entries-2026-03 was not loaded to the end"
fails_saying "check_opensearch_index_complete, where OpenSearch does not say," \
    "load_state() { echo unknown; }; check_opensearch_index_complete uniprot_entries-2026-03" \
    "OpenSearch did not say whether uniprot_entries-2026-03"
both_ways check_opensearch_index_open \
    "index_status() { echo open; }; check_opensearch_index_open uniprot_entries-2026-01 2026-01" \
    "index_status() { echo close; }; check_opensearch_index_open uniprot_entries-2026-01 2026-01" \
    "uniprot_entries-2026-01, of the version this host serves, is not open"
fails_saying "check_opensearch_index_open, of an index not there," \
    "index_status() { echo; }; check_opensearch_index_open uniprot_entries-2026-01 2026-01" \
    "is not in OpenSearch, so a switch that fails could not go back to it. Load it with load.sh --uniprot-version 2026-01"

# Another host, reached through a stand-in that runs the command here, as clone.sh's remote_sh and
# distribute.sh's on would run it there.
REMOTE='remote_sh() { bash -c "$*"; }; REMOTE_ADDRESS=elsewhere'
both_ways check_remote_db_present "${REMOTE}; check_remote_db_present '${DB}'" "${REMOTE}; check_remote_db_present '${EMPTY}/gone'" "the remote host has no ${EMPTY}/gone"
both_ways check_remote_db_whole "${REMOTE}; check_remote_db_whole '${DB}'" "${REMOTE}; check_remote_db_whole '${EMPTY}'" "${EMPTY} has no tables/uniprot_entries.tsv.lz4"
mkdir -p "${TEMP_DIR}/checks/lost/suffix-array"
both_ways check_copy_kept_kmer_table \
    "${REMOTE}; check_copy_kept_kmer_table '${DB}' '${DB}'" \
    "${REMOTE}; check_copy_kept_kmer_table '${TEMP_DIR}/checks/lost' '${DB}'" \
    "the remote has a k-mer table and the copy does not"
fails_saying "check_copy_kept_kmer_table, where it cannot ask," \
    "remote_sh() { return 255; }; REMOTE_ADDRESS=elsewhere; check_copy_kept_kmer_table '${DB}' '${DB}'" \
    "could not ask elsewhere whether it has a k-mer table"
SERVER="on() { local host=\$1 root=\$2; shift 2; (cd \"\$root\" && \"\$@\"); }; SOURCE=source SOURCE_OUTPUT_DIR=/data"
mkdir -p "${TEMP_DIR}/checks/server/deploy/server" "${TEMP_DIR}/checks/bare"
# The server's clone.sh cannot clone the version named never.
for script in verify clone load; do
    make_stub "${TEMP_DIR}/checks/server/deploy/server/${script}.sh" 'case "$*" in *never*) exit 1 ;; esac' > /dev/null
done
both_ways check_server_scripts "${SERVER}; check_server_scripts a host '${TEMP_DIR}/checks/server'" "${SERVER}; check_server_scripts b host '${TEMP_DIR}/checks/bare'" \
    "b cannot be reached, or has no scripts installed in ${TEMP_DIR}/checks/bare"
both_ways check_server_can_clone \
    "${SERVER}; UNIPROT_VERSION=2026-03; check_server_can_clone a host '${TEMP_DIR}/checks/server'" \
    "${SERVER}; UNIPROT_VERSION=never; check_server_can_clone a host '${TEMP_DIR}/checks/server'" \
    "a cannot clone never from source"


section "every script's --help"

# Every option in one column, and which setting wins said the same way. From a copy with an empty
# deploy.conf of its own, which a script reads before any other, and install.sh with a --prefix of
# its own, so no deploy.conf on this machine is read or checked first.
copy_deploy_scripts "${HERE}/../.." "${TEMP_DIR}/checkout"
DEPLOY="${TEMP_DIR}/checkout/.deploy"
: > "${DEPLOY}/deploy.conf"
for script in build distribute server/clone server/load server/prune server/switch server/verify server/install server/opensearch/install; do
    arguments=(--help)
    [[ "$script" != server/*install ]] || arguments=(--prefix "${TEMP_DIR}/prefix" --help)
    output=$("${DEPLOY}/${script}.sh" "${arguments[@]}" 2>&1)
    check "${script}.sh --help exits 0" "$?" "0"
    check_true "and lists its options" grep -q '^  --' <<< "$output"
    check "and every option line has its text in the thirtieth column" \
        "$(awk '/^  --/ && (substr($0, 29, 1) != " " || substr($0, 30, 1) == " ")' <<< "$output" | wc -l | tr -d ' ')" "0"
    check_true "and says that a flag wins over deploy.conf" \
        grep -q '^A flag wins over .*deploy.conf, which wins over the defaults' <<< "$output"
done

# The version clone.sh copies can come from deploy.conf, so it is checked there too.
printf 'UNIPROT_VERSION=2026.03\n' > "${DEPLOY}/deploy.conf"
output=$("${DEPLOY}/server/clone.sh" --remote-address host --local-ssh-key key 2>&1)
check "clone.sh refuses a version in deploy.conf not written YYYY-MM" "$?" "2"
check "and says how to write it" "$output" "Error: a UniProtKB version is written YYYY-MM, not '2026.03'."
: > "${DEPLOY}/deploy.conf"

# Every script that takes --uniprot-version checks it is written YYYY-MM, before anything else.
for script in server/clone distribute server/load server/switch server/verify; do
    output=$("${DEPLOY}/${script}.sh" --uniprot-version 2026.03 2>&1)
    check "${script}.sh refuses --uniprot-version 2026.03" "$?" "2"
    check "and says how to write it" "$output" "Error: a UniProtKB version is written YYYY-MM, not '2026.03'."
done

output=$("${DEPLOY}/build.sh" --opensearch-url http://localhost:9200 2>&1)
check "build.sh, which loads nothing into OpenSearch, refuses --opensearch-url" "$?" "2"
check "as an unknown option" "$output" "Error: unknown option '--opensearch-url'. Run with --help for the options."


summary
