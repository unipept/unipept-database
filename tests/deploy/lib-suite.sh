#!/usr/bin/env bash
#
# The parts of .deploy/lib.sh, function by function, for what the scripts that use them seldom or
# never reach: core.sh's cases, which every repository that shares it runs, and then this
# repository's own: an API binary that says nothing useful, paths that resolve to nothing. The
# rest each part does is checked through the scripts, in the verify, deploy and opensearch suites.
# Needs no container and no network.

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


section "api.sh: api_follows_current"

mkdir -p "${TEMP_DIR}/data"
printf 'INDEX_LOCATION=%s/data/current/suffix-array/\n' "$TEMP_DIR" > "${TEMP_DIR}/api.env"
in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/data'; api_follows_current"
check "an INDEX_LOCATION through current in OUTPUT_DIR follows it" "$?" "0"

ln -s "${TEMP_DIR}/data" "${TEMP_DIR}/data-link"
in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/data-link/'; api_follows_current"
check "as does an OUTPUT_DIR that is a link to that directory" "$?" "0"

mkdir -p "${TEMP_DIR}/elsewhere"
in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/elsewhere'; api_follows_current"
check "a current in another directory is not followed" "$?" "1"

printf 'INDEX_LOCATION=%s/gone/away/current/suffix-array\n' "$TEMP_DIR" > "${TEMP_DIR}/gone.env"
in_lib "API_ENV_FILE='${TEMP_DIR}/gone.env' OUTPUT_DIR='${TEMP_DIR}/not/there'; api_follows_current"
check "two paths that resolve to nothing are not the same one" "$?" "1"

in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/not/there'; api_follows_current"
check "nor is an OUTPUT_DIR that resolves to nothing" "$?" "1"

printf 'INDEX_LOCATION=%s/data/uniprot-2026-03/suffix-array\n' "$TEMP_DIR" > "${TEMP_DIR}/direct.env"
in_lib "API_ENV_FILE='${TEMP_DIR}/direct.env' OUTPUT_DIR='${TEMP_DIR}/data'; api_follows_current"
check "an INDEX_LOCATION that names a version's directory itself does not follow current" "$?" "1"


section "api.sh: api_binary_version and api_state"

# A stand-in API binary that answers --version with what it is given.
fake_api() {
    local binary="${TEMP_DIR}/api-$1"
    printf '#!/bin/sh\n%s\n' "$2" > "$binary"
    chmod +x "$binary"
    echo "$binary"
}

check "the version is the last word of what --version prints" \
    "$(in_lib "api_binary_version '$(fake_api plain 'echo unipept-api 2.7.0')'")" "2.7.0"
check "without a pre-release suffix" \
    "$(in_lib "api_binary_version '$(fake_api rc 'echo unipept-api 2.7.0-rc.1')'")" "2.7.0"

in_lib "api_binary_version '$(fake_api failing 'echo unipept-api 2.7.0; exit 3')'" > /dev/null
check "a binary whose --version fails has no version" "$?" "1"
in_lib "api_binary_version '$(fake_api garbled 'echo unipept-api, built today')'" > /dev/null
check "nor does one that prints no X.Y.Z" "$?" "1"
in_lib "api_binary_version '${TEMP_DIR}/no-such-binary'" > /dev/null
check "nor one that is not there" "$?" "1"

in_lib "api_state '$(fake_api new 'echo unipept-api 2.7.0')'"
check "a release since API_VERSIONED_INDEX_SINCE queries the versioned index" "$?" "0"
in_lib "api_state '$(fake_api newer 'echo unipept-api 2.10.0')'"
check "and so does a later one, compared as versions rather than text" "$?" "0"
in_lib "api_state '$(fake_api old 'echo unipept-api 2.6.4')'"
check "an older release does not" "$?" "1"
in_lib "api_state '$(fake_api garbled 'echo unipept-api, built today')'"
check "and one that cannot say is neither" "$?" "2"


section "api.sh: is_served"

# What OpenSearch says is replaced, so the links alone decide, and the case of an OpenSearch that
# answers but does not say what the alias points at can be made.
mkdir -p "${TEMP_DIR}/served/uniprot-2026-03"
ln -s uniprot-2026-03 "${TEMP_DIR}/served/current"
answers_without_alias="OUTPUT_DIR='${TEMP_DIR}/served' API_ENV_FILE=/nonexistent
opensearch_answers() { return 0; }
alias_targets() { return 1; }"

in_lib "${answers_without_alias}; is_served 2026-03"
check "what current points at is served" "$?" "0"
in_lib "${answers_without_alias}; is_served 2026-04"
check "another version is not" "$?" "1"

output=$(in_lib "${answers_without_alias}; is_served 2026-04 strict" 2>&1)
check "strict, an alias OpenSearch does not report stops the script" "$?" "2"
check_true "and says what is not known" grep -q "so what this host serves is not known" <<< "$output"

in_lib "OUTPUT_DIR='${TEMP_DIR}/served' API_ENV_FILE=/nonexistent
opensearch_answers() { return 1; }
alias_targets() { return 1; }
is_served 2026-04 strict"
check "an OpenSearch that does not answer at all leaves it to the links" "$?" "1"


section "checks.sh: each check, passing and failing"

# One check, run as a script runs it, in a good setting and in one made bad for it: it passes in
# the first, and fails in the second saying what is wrong. Each setting is the code before the check,
# with stand-ins for what a check would otherwise ask of OpenSearch, the API or another host.
both_ways() {
    local name=$1 good=$2 bad=$3 says=$4 output
    in_lib "$good" > /dev/null 2>&1
    check "${name} passes" "$?" "0"
    output=$(in_lib "$bad" 2>&1)
    check "${name} fails" "$?" "1"
    check_true "and says so" grep -qF -- "$says" <<< "$(grep '^FAIL ' <<< "$output")"
}

# A whole database, and one with no files in it.
DB="${TEMP_DIR}/checks/uniprot-2026-03"
mkdir -p "${DB}/tables" "${TEMP_DIR}/checks/empty"
# shellcheck disable=SC2016 # expanded by the bash in_lib starts
in_lib 'printf "%s\n" "${INDEX_FILES[@]}" "${OPTIONAL_INDEX_FILES[@]}"' | while read -r relative; do
    mkdir -p "$(dirname "${DB}/suffix-array/${relative}")"
    printf 'content\n' > "${DB}/suffix-array/${relative}"
done
printf '2026.03\n' > "${DB}/suffix-array/.version"
printf 'rows\n' > "${DB}/tables/uniprot_entries.tsv.lz4"
EMPTY="${TEMP_DIR}/checks/empty"

both_ways check_db_present "check_db_present '${DB}'" "check_db_present '${TEMP_DIR}/checks/gone'" "there is no ${TEMP_DIR}/checks/gone"
both_ways check_db_whole "check_db_whole '${DB}'" "check_db_whole '${EMPTY}'" "${EMPTY} is not a database the API can serve"
both_ways check_db_table "check_db_table '${DB}'" "check_db_table '${EMPTY}'" "${EMPTY} has no tables/uniprot_entries.tsv.lz4"

both_ways check_lock_usable \
    "OPENSEARCH_LOCK='${TEMP_DIR}/checks/lock'; check_lock_usable 'the work'" \
    "OPENSEARCH_LOCK='${TEMP_DIR}/checks/no/such/dir/lock'; check_lock_usable 'the work'" \
    "cannot open the lock ${TEMP_DIR}/checks/no/such/dir/lock"
both_ways check_build_disk "check_build_disk '${DB}' 1000 1500" "check_build_disk '${DB}' 1000 1499" "is free on disk"
# Stand-ins for systemctl, the API's deploy.sh, sudo and ssh, on a PATH of their own.
mkdir -p "${TEMP_DIR}/checks/bin"
printf '#!/bin/sh\n[ -e "%s/checks/opensearch-active" ]\n' "$TEMP_DIR" > "${TEMP_DIR}/checks/bin/systemctl"
printf '#!/bin/sh\n[ -e "%s/checks/sudo-allowed" ]\n' "$TEMP_DIR" > "${TEMP_DIR}/checks/bin/sudo"
chmod +x "${TEMP_DIR}/checks/bin/"*
STAND_INS="PATH='${TEMP_DIR}/checks/bin':\$PATH"
both_ways check_build_opensearch_stopped \
    "${STAND_INS}; check_build_opensearch_stopped" \
    "${STAND_INS}; touch '${TEMP_DIR}/checks/opensearch-active'; check_build_opensearch_stopped" \
    "OpenSearch is running"
rm -f "${TEMP_DIR}/checks/opensearch-active"
both_ways check_sudo_opensearch \
    "${STAND_INS}; touch '${TEMP_DIR}/checks/sudo-allowed'; check_sudo_opensearch" \
    "${STAND_INS}; rm -f '${TEMP_DIR}/checks/sudo-allowed'; check_sudo_opensearch" \
    "may not stop and start OpenSearch through sudo"

# What the kernel says of memory and processes, where it says it: /proc is Linux's.
if [ -r /proc/meminfo ]; then
    available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    both_ways check_build_memory "check_build_memory '${DB}' 1" "check_build_memory '${DB}' $((available * 2))" "of memory is available"
    cp "$(command -v sleep)" "${TEMP_DIR}/checks/unipept-api"
    in_lib "check_build_api_stopped" > /dev/null 2>&1
    check "check_build_api_stopped passes" "$?" "0"
    "${TEMP_DIR}/checks/unipept-api" 30 &
    running=$!
    output=$(in_lib "check_build_api_stopped" 2>&1)
    check "check_build_api_stopped fails" "$?" "1"
    check_true "and says so" grep -qF "FAIL The Unipept API is running" <<< "$output"
    kill "$running" 2> /dev/null
    wait "$running" 2> /dev/null
fi

# The API, as unipept-api's install lays it out: a deploy.sh that says what it takes, and a binary
# that says its version.
API_GOOD="API_DEPLOY='$(fake_api deploy-good 'echo "usage: deploy.sh start"')' API_BINARY='$(fake_api new-api 'echo unipept-api 2.7.0')'"
API_BAD="API_DEPLOY='$(fake_api deploy-old 'echo "usage: deploy.sh deploy"; exit 1')' API_BINARY='$(fake_api old-api 'echo unipept-api 2.6.4')'"
both_ways check_api_stop_start "${API_GOOD}; check_api_stop_start" "${API_BAD}; check_api_stop_start" "has no stop and start"
both_ways check_api_version "${API_GOOD}; check_api_version" "${API_BAD}; check_api_version" "the API installed is 2.6.4, older than 2.7.0"
cp "$(fake_api old-rollback 'echo unipept-api 2.6.4')" "$(fake_api new-api 'echo unipept-api 2.7.0').previous"
both_ways check_api_rollback_version \
    "API_BINARY='${TEMP_DIR}/api-no-rollback'; check_api_rollback_version" \
    "API_BINARY='${TEMP_DIR}/api-new-api'; check_api_rollback_version" \
    "deploy.sh rollback would go back to ${TEMP_DIR}/api-new-api.previous"
both_ways check_api_accepts "${API_GOOD}; check_api_accepts '${DB}'" "API_DEPLOY='$(fake_api refuses 'exit 1')'; check_api_accepts '${DB}'" "the API's own check refuses ${DB}/suffix-array"

# The links of a host whose API follows current, and of one whose does not.
LINKS="${TEMP_DIR}/checks/links"
mkdir -p "${LINKS}/data/uniprot-2026-03"
ln -sfn uniprot-2026-03 "${LINKS}/data/current"
printf 'INDEX_LOCATION=%s/data/current/suffix-array\n' "$LINKS" > "${LINKS}/follows.env"
printf 'INDEX_LOCATION=%s/data/uniprot-2026-03/suffix-array\n' "$LINKS" > "${LINKS}/fixed.env"
both_ways check_links_follows_current \
    "OUTPUT_DIR='${LINKS}/data' API_ENV_FILE='${LINKS}/follows.env'; check_links_follows_current" \
    "OUTPUT_DIR='${LINKS}/data' API_ENV_FILE='${LINKS}/fixed.env'; check_links_follows_current" \
    "so the API would not follow the switch"
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
both_ways check_index_to_go_back_to \
    "index_status() { echo open; }; is_complete() { return 0; }; check_index_to_go_back_to uniprot_entries-2026-01" \
    "index_status() { echo close; }; is_complete() { return 0; }; check_index_to_go_back_to uniprot_entries-2026-01" \
    "uniprot_entries-2026-01, of the version this host serves, is not open and loaded to the end"
both_ways check_index_present "check_index_present uniprot_entries-2026-03 2026-03 open" "check_index_present uniprot_entries-2026-03 2026-03 ''" \
    "uniprot_entries-2026-03 is not in OpenSearch. Load it with load.sh --uniprot-version 2026-03"
both_ways check_index_complete \
    "is_complete() { return 0; }; check_index_complete uniprot_entries-2026-03" \
    "is_complete() { return 1; }; check_index_complete uniprot_entries-2026-03" \
    "uniprot_entries-2026-03 was not loaded to the end"

# Another host, reached through a stand-in that runs the command here, as clone.sh's remote_sh and
# distribute.sh's on would run it there.
REMOTE='remote_sh() { bash -c "$*"; }; REMOTE_ADDRESS=elsewhere'
both_ways check_remote_db_present "${REMOTE}; check_remote_db_present '${DB}'" "${REMOTE}; check_remote_db_present '${EMPTY}/gone'" "the remote host has no ${EMPTY}/gone"
both_ways check_remote_db_whole "${REMOTE}; check_remote_db_whole '${DB}'" "${REMOTE}; check_remote_db_whole '${EMPTY}'" "the database on elsewhere is missing files the API needs"
mkdir -p "${TEMP_DIR}/checks/lost/suffix-array"
both_ways check_copy_kept_kmer_table \
    "${REMOTE}; check_copy_kept_kmer_table '${DB}' '${DB}'" \
    "${REMOTE}; check_copy_kept_kmer_table '${TEMP_DIR}/checks/lost' '${DB}'" \
    "the remote has a k-mer table and the copy does not"
output=$(in_lib "remote_sh() { return 255; }; REMOTE_ADDRESS=elsewhere; check_copy_kept_kmer_table '${DB}' '${DB}'" 2>&1)
check "check_copy_kept_kmer_table fails where it cannot ask" "$?" "1"
check_true "and says so" grep -qF "FAIL could not ask elsewhere whether it has a k-mer table" <<< "$output"
SERVER="on() { local host=\$1 root=\$2; shift 2; (cd \"\$root\" && \"\$@\"); }; UNIPROT_VERSION=2026-03 SOURCE=source"
mkdir -p "${TEMP_DIR}/checks/server/bin" "${TEMP_DIR}/checks/bare"
# The server's clone.sh cannot clone the version named never.
for script in verify clone load; do printf '#!/bin/sh\ncase "$*" in *never*) exit 1 ;; esac\n' > "${TEMP_DIR}/checks/server/bin/${script}.sh"; done
chmod +x "${TEMP_DIR}/checks/server/bin/"*
both_ways check_server_scripts "${SERVER}; check_server_scripts a host '${TEMP_DIR}/checks/server'" "${SERVER}; check_server_scripts b host '${TEMP_DIR}/checks/bare'" \
    "b cannot be reached, or has no scripts installed in ${TEMP_DIR}/checks/bare"
both_ways check_server_can_clone "${SERVER}; check_server_can_clone a host '${TEMP_DIR}/checks/server' --uniprot-version 2026-03" \
    "${SERVER}; UNIPROT_VERSION=never; check_server_can_clone a host '${TEMP_DIR}/checks/server' --uniprot-version never" \
    "a cannot clone never from source"


section "every script's --help"

# Every option in one column, and which setting wins said the same way. From a copy with an empty
# deploy.conf of its own, which a script reads before any other, and install.sh with a --prefix of
# its own, so no deploy.conf on this machine is read or checked first.
copy_deploy_scripts "${HERE}/../.." "${TEMP_DIR}/checkout"
DEPLOY="${TEMP_DIR}/checkout/.deploy"
: > "${DEPLOY}/deploy.conf"
for script in build clone distribute load migrate prune switch verify opensearch/install; do
    arguments=(--help)
    [ "$script" != opensearch/install ] || arguments=(--prefix "${TEMP_DIR}/prefix" --help)
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
output=$("${DEPLOY}/clone.sh" --remote-address host --local-ssh-key key 2>&1)
check "clone.sh refuses a version in deploy.conf not written YYYY-MM" "$?" "2"
check "and says how to write it" "$output" "Error: a UniProtKB version is written YYYY-MM, not '2026.03'."
: > "${DEPLOY}/deploy.conf"

# Every script that takes --uniprot-version checks it is written YYYY-MM, before anything else.
for script in clone distribute load switch verify; do
    output=$("${DEPLOY}/${script}.sh" --uniprot-version 2026.03 2>&1)
    check "${script}.sh refuses --uniprot-version 2026.03" "$?" "2"
    check "and says how to write it" "$output" "Error: a UniProtKB version is written YYYY-MM, not '2026.03'."
done

output=$("${DEPLOY}/build.sh" --opensearch-url http://localhost:9200 2>&1)
check "build.sh, which loads nothing into OpenSearch, refuses --opensearch-url" "$?" "2"
check "as an unknown option" "$output" "Error: unknown option '--opensearch-url'. Run with --help for the options."


summary
