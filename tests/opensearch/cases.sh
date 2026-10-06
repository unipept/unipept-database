#!/usr/bin/env bash
#
# Runs inside the client container, against the OpenSearch reached at $OPENSEARCH_URL.
# Started by load-suite.sh, which is what brings both containers up.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/../.."

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

WORK="$(mktemp -d)"
rc=0
FIXTURE="${WORK}/uniprot_entries.tsv.lz4"

# Eight columns, the layout of the uniprot_entries table. The loader takes columns 2 to 8.
write_fixture() {
    local target=$1
    shift
    printf '%s\n' "$@" | lz4 -c > "$target" 2> /dev/null
}

row() { printf '%s\t%s\t1\t9606\tswissprot\t%s\tMKVLAAGIVGVL\tEC:1.1.1.1;GO:0005515;IPR:IPR000001' "$1" "$2" "$3"; }
short_row() { printf '%s\t%s\t1\t9606' "$1" "$2"; }

# Runs the loader and leaves its exit status in `rc` and its output in $1.
load() {
    local logfile=$1
    shift
    "${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}

documents_in() {
    curl -s "${OPENSEARCH_URL}/$1/_count" | tr ',' '\n' | sed -n 's/.*"count":\([0-9]*\).*/\1/p' | head -1
}

index_exists() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' "${OPENSEARCH_URL}/$1")" = 200 ]
}


section "a load leaves an index it does not own alone"
curl -s -X PUT "${OPENSEARCH_URL}/unrelated_index" -H 'Content-Type: application/json' \
    -d '{"mappings":{"properties":{"note":{"type":"keyword"}}}}' > /dev/null
curl -s -X POST "${OPENSEARCH_URL}/unrelated_index/_doc/1?refresh=true" -H 'Content-Type: application/json' \
    -d '{"note":"keep me"}' > /dev/null
check_true "the unrelated index is there to start with" index_exists unrelated_index

write_fixture "$FIXTURE" "$(row 1 P00001 'First protein')" "$(row 2 P00002 'Second protein')" "$(row 3 P00003 'Third protein')"
load "${WORK}/load.log" --uniprot-entries "$FIXTURE"
check_true "the load succeeds" [ "$rc" -eq 0 ]
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries/_refresh" > /dev/null
check_true "the unrelated index survives the load" index_exists unrelated_index
check "every row is indexed" "$(documents_in uniprot_entries)" "3"


section "the index has the settings the API depends on"
# From the mapping file, under settings.index; misplaced, OpenSearch ignores them silently.
settings="$(curl -s "${OPENSEARCH_URL}/uniprot_entries/_settings?flat_settings=true")"
check_true "no replicas, which a single node cannot place" grep -q '"index.number_of_replicas":"0"' <<< "$settings"
check_true "the result window the API pages within" grep -q '"index.max_result_window":"10000"' <<< "$settings"
check_true "so the index is green" grep -q '"status":"green"' \
    <<< "$(curl -s "${OPENSEARCH_URL}/_cluster/health/uniprot_entries")"


section "a row of the wrong width stops the load and says where"
write_fixture "${WORK}/short.tsv.lz4" "$(row 1 P00001 'First protein')" "$(short_row 2 P00002)"
load "${WORK}/short.log" --uniprot-entries "${WORK}/short.tsv.lz4"
check_true "the load reports a failure" [ "$rc" -ne 0 ]
check_true "the failure names the line" grep -q 'line 2' "${WORK}/short.log"
check_true "the failure says where to continue" grep -q -- '--skip' "${WORK}/short.log"


section "continuing an upload keeps what is already indexed"
write_fixture "$FIXTURE" "$(row 1 P00001 'First protein')" "$(row 2 P00002 'Second protein')" "$(row 3 P00003 'Third protein')"
load /dev/null --uniprot-entries "$FIXTURE"
curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries/_doc/P00003?refresh=true" > /dev/null
check "one document is gone" "$(documents_in uniprot_entries)" "2"
load /dev/null --uniprot-entries "$FIXTURE" --skip 2
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries/_refresh" > /dev/null
check "the index was not dropped and the rest was added" "$(documents_in uniprot_entries)" "3"


# Where the uniprot_entries alias points, or nothing.
alias_target() { curl -s "${OPENSEARCH_URL}/_cat/aliases/uniprot_entries?h=index" | tr -d '[:space:]'; }

not_in() { ! grep -q "$1" "$2"; }
not_served() { ! served "$@"; }
not_ready() { ! ready "$@"; }

# open, close, or nothing for an index that is not there.
status_of() { curl -s "${OPENSEARCH_URL}/_cat/indices/$1?h=status&expand_wildcards=all" 2> /dev/null | grep -xE 'open|close'; }

# Loads the given accessions into a versioned index.
load_version() {
    local index=$1 accession
    shift
    local rows=()
    for accession in "$@"; do rows+=("$(row 1 "$accession" "Protein ${accession}")"); done
    write_fixture "${WORK}/${index}.tsv.lz4" "${rows[@]}"
    load "${WORK}/${index}.log" --uniprot-entries "${WORK}/${index}.tsv.lz4" --index-name "$index"
    curl -s -X POST "${OPENSEARCH_URL}/${index}/_refresh" > /dev/null
}


section "a versioned index is loaded beside the one the API queries"
load_version uniprot_entries-2026-01 P10001 P10002
check_true "the load succeeds" [ "$rc" -eq 0 ]
check "the versioned index holds its rows" "$(documents_in uniprot_entries-2026-01)" "2"
check "the index the API queries is untouched" "$(documents_in uniprot_entries)" "3"
check "and is still an index, not an alias" "$(alias_target)" ""
"${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name uniprot_entries-2026-01 --check-complete
check "it is marked as loaded to the end" "$?" "0"


section "a load continued with --skip needs the index it continues"
load "${WORK}/skip-missing.log" --uniprot-entries "$FIXTURE" --index-name uniprot_entries-2031-01 --skip 1
check_true "a --skip into an index that is not there is refused" [ "$rc" -ne 0 ]
check_true "and says to load from the start" grep -q 'Load it from the start' "${WORK}/skip-missing.log"
check "without creating it" "$(status_of uniprot_entries-2031-01)" ""


section "a load that stops part way"
# What a load that was stopped after its first batch leaves: the index, some rows, and no mark. A
# row of the wrong width stops the load before its batch is sent, so it cannot stand in for this.
curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries-2026-07" -H 'Content-Type: application/json' \
    -d @"${REPO}/opensearch/mappings/uniprot_entries.json" > /dev/null
curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries-2026-07/_doc/P70001?refresh=true" -H 'Content-Type: application/json' \
    -d '{"uniprot_accession_number":"P70001","version":1,"taxon_id":9606,"type":"swissprot","name":"First protein","sequence":"MKV","fa":""}' > /dev/null
check "the stopped load left a row" "$(documents_in uniprot_entries-2026-07)" "1"
"${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name uniprot_entries-2026-07 --check-complete
check "the index is not marked as loaded to the end" "$?" "1"
"${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name uniprot_entries-2030-01 --check-complete
check "nor is an index that is not there" "$?" "1"

write_fixture "${WORK}/rest.tsv.lz4" "$(row 1 P70001 'First protein')" "$(row 2 P70002 'Second protein')"
load /dev/null --uniprot-entries "${WORK}/rest.tsv.lz4" --index-name uniprot_entries-2026-07 --skip 1
"${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name uniprot_entries-2026-07 --check-complete
check "continued to the end, it is marked" "$?" "0"
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2026-07/_refresh" > /dev/null
check "with every row" "$(documents_in uniprot_entries-2026-07)" "2"


# The API installed on a host, as prune.sh and switch.sh ask it: by its --version, which a case sets.
API_BIN=/tmp/api-bin/unipept-api
mkdir -p /tmp/api-bin
echo 2.7.0 > /tmp/api-bin/version
# shellcheck disable=SC2016 # expands when the stand-in runs
printf '#!/bin/sh\necho "unipept-api $(cat /tmp/api-bin/version)"\n' > "$API_BIN"
chmod -R a+rX /tmp/api-bin
chmod 755 "$API_BIN"
# The one deploy.sh keeps to roll back to, where a case puts it, with its own version.
roll_back_to() {
    printf '#!/bin/sh\necho "unipept-api %s"\n' "$1" > "${API_BIN}.previous"
    chmod 755 "${API_BIN}.previous"
}


section ".deploy/prune.sh"
# As the user the .deploy scripts run as, with each version's directory beside its index, the way
# a host holds them, and the current link where install.sh and switch.sh put it. 2026-01 and
# 2026-02 have only their index left, and uniprot_entries-legacy is what a host loaded before
# versioned indices kept.
DATA=/tmp/prune-data
rm -rf "${DATA:?}"
load_version uniprot_entries-legacy P00009
for version in 2026-01 2026-02 2026-03 2026-04 2026-05; do
    load_version "uniprot_entries-${version}" "P${version//-/}"
done
for version in 2026-03 2026-04 2026-05 2026-07; do
    mkdir -p "${DATA}/uniprot-${version}/suffix-array"
done
ln -s uniprot-2026-07 "${DATA}/current"
chown -R -h unipept: "$DATA"

prune() {
    local logfile=$1
    shift
    runuser -u unipept -- "${REPO}/.deploy/prune.sh" --output-dir "$DATA" --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}

prune "${WORK}/prune-dry.log" --keep 2 --dry-run
check_true "a dry run succeeds" [ "$rc" -eq 0 ]
check_true "and names what it would remove, newest first" grep -q 'Removing: 2026-03 2026-02 2026-01$' "${WORK}/prune-dry.log"
check "without removing an index" "$(status_of uniprot_entries-2026-01)" "open"
check_true "or a directory" test -d "${DATA}/uniprot-2026-03"

prune "${WORK}/prune.log" --keep 2
check_true "it succeeds" [ "$rc" -eq 0 ]
check_true "and says what this host serves" grep -q 'This host serves 2026-07' "${WORK}/prune.log"
check "the version this host serves is kept" "$(documents_in uniprot_entries-2026-07) $([ -d "${DATA}/uniprot-2026-07" ] && echo kept)" "2 kept"
check "the two before it are kept, index and files" \
    "$(status_of uniprot_entries-2026-05) $(status_of uniprot_entries-2026-04) $([ -d "${DATA}/uniprot-2026-04" ] && echo kept)" \
    "open open kept"
check "older ones lose their index" "$(status_of uniprot_entries-2026-03)$(status_of uniprot_entries-2026-01)" ""
# Nothing says INDEX_LOCATION goes through current here, so an older API may still query it.
check "uniprot_entries-legacy is kept, which may be the only copy of what an older API serves" "$(status_of uniprot_entries-legacy)" "open"
check "and their files" "$([ -e "${DATA}/uniprot-2026-03" ] && echo left || echo removed)" "removed"
check "current is left as it is" "$(readlink "${DATA}/current")" "uniprot-2026-07"

section ".deploy/prune.sh keeps the version switch.sh --back goes to"
as_unipept_link() { runuser -u unipept -- ln -sfn "$1" "${DATA}/$2"; }
as_unipept_link uniprot-2026-04 previous
prune "${WORK}/prune-previous.log" --keep 0
check_true "it succeeds" [ "$rc" -eq 0 ]
check_true "and says which it switched from" grep -q 'and switched from 2026-04' "${WORK}/prune-previous.log"
check "the one before is kept, with its files" "$(status_of uniprot_entries-2026-04) $([ -d "${DATA}/uniprot-2026-04" ] && echo kept)" "open kept"
check "and everything between the two" "$(status_of uniprot_entries-2026-05)" "open"
runuser -u unipept -- unlink "${DATA}/previous"

section ".deploy/prune.sh keeps what INDEX_LOCATION names"
# A host whose API still reads a version's directory itself, rather than through current.
printf 'INDEX_LOCATION=%s/uniprot-2026-04/suffix-array\n' "$DATA" > /tmp/prune-api.env
chmod 644 /tmp/prune-api.env
prune_with_api() {
    local logfile=$1
    shift
    runuser -u unipept -- env API_ENV_FILE=/tmp/prune-api.env API_BINARY="$API_BIN" "${REPO}/.deploy/prune.sh" --output-dir "$DATA" \
        --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}
prune_with_api "${WORK}/prune-inuse.log" --keep 0
check_true "it succeeds" [ "$rc" -eq 0 ]
check_true "and counts what INDEX_LOCATION names as served" grep -q 'This host serves 2026-07 2026-04' "${WORK}/prune-inuse.log"
check "that version is kept, with its files" "$(status_of uniprot_entries-2026-04) $([ -d "${DATA}/uniprot-2026-04" ] && echo kept)" "open kept"
check "and uniprot_entries itself, which an API reading it that way may still query" "$(status_of uniprot_entries)" "open"

# Once INDEX_LOCATION goes through current, the API queries the versioned index, and uniprot_entries
# itself is the oldest.
printf 'INDEX_LOCATION=%s/current/suffix-array\n' "$DATA" > /tmp/prune-api.env
prune_with_api "${WORK}/prune-plain.log" --keep 1 --dry-run
check_true "uniprot_entries itself is then removed as the oldest" grep -q 'Removing:.* plain$' "${WORK}/prune-plain.log"
check "not on a dry run" "$(status_of uniprot_entries)" "open"

# But not while the API installed is one that queries it, whatever INDEX_LOCATION says.
echo 2.6.0 > /tmp/api-bin/version
prune_with_api "${WORK}/prune-oldapi.log" --keep 1 --dry-run
check "an older API keeps uniprot_entries itself" "$(grep -c 'plain' "${WORK}/prune-oldapi.log")" "0"
echo 2.7.0 > /tmp/api-bin/version
roll_back_to 2.6.0
prune_with_api "${WORK}/prune-oldprevious.log" --keep 1 --dry-run
check "and so does an older one deploy.sh would roll back to" "$(grep -c 'plain' "${WORK}/prune-oldprevious.log")" "0"
check_true "and it says why" grep -q "from before versioned indices, are kept: ${API_BIN}.previous is older than 2.7.0" "${WORK}/prune-oldprevious.log"
chmod 644 "${API_BIN}.previous"
prune_with_api "${WORK}/prune-norun.log" --keep 1 --dry-run
check_true "one it cannot run is said to be that" grep -q "${API_BIN}.previous cannot be run" "${WORK}/prune-norun.log"
rm -f "${API_BIN}.previous"

# Unless the index of the version it serves is not whole to serve from: then it may be the only copy.
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2026-07/_close" > /dev/null
prune_with_api "${WORK}/prune-notwhole.log" --keep 1 --dry-run
check "while the served version's index is not open, uniprot_entries itself is not a candidate" \
    "$(grep -c 'plain' "${WORK}/prune-notwhole.log")" "0"
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2026-07/_open" > /dev/null

# With the API's own settings the ones that say what it reads, it will not guess past them.
chmod 600 /tmp/prune-api.env
prune_with_api "${WORK}/prune-unreadable.log" --keep 0
check "settings it cannot read stop it" "$rc" "2"
check_true "and say so" grep -q 'cannot read /tmp/prune-api.env' "${WORK}/prune-unreadable.log"
rm -f /tmp/prune-api.env


section ".deploy/prune.sh keeps a version loaded ahead of a switch"
load_version uniprot_entries-2026-09 P90001
mkdir -p "${DATA}/uniprot-2026-09/suffix-array" && chown -R unipept: "${DATA}/uniprot-2026-09"
prune "${WORK}/prune-ahead.log" --keep 0
check_true "it succeeds" [ "$rc" -eq 0 ]
check "the newer version is kept, though --keep is 0" "$(status_of uniprot_entries-2026-09) $([ -d "${DATA}/uniprot-2026-09" ] && echo kept)" "open kept"
check "the version this host serves is kept" "$(status_of uniprot_entries-2026-07)" "open"
check "everything older is removed" "$(status_of uniprot_entries-2026-05)$(status_of uniprot_entries-2026-04)" ""
check "files included" "$(find "$DATA" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')" "current uniprot-2026-07 uniprot-2026-09 "

section ".deploy/prune.sh refuses what it cannot decide"
prune "${WORK}/prune-nokeep.log"
check "without --keep it stops" "$rc" "2"
# A load or a switch holds the lock; removing versions under either could take what it works on.
mkdir -p /run/lock
chmod 1777 /run/lock
runuser -u unipept -- touch /run/lock/unipept-opensearch.lock
# shellcheck disable=SC2016 # $1 belongs to the inner shell
setpriv --reuid unipept --regid unipept --init-groups bash -c 'exec 9>> "$1"; flock -s 9; exec sleep 30' _ /run/lock/unipept-opensearch.lock &
holder=$!
for _ in $(seq 50); do
    runuser -u unipept -- flock -n -x /run/lock/unipept-opensearch.lock true 2> /dev/null || break
    sleep 0.1
done
prune "${WORK}/prune-locked.log" --keep 0
check "a load or a switch running stops it" "$rc" "2"
check_true "and says so" grep -q 'is running on this host; wait for it to finish' "${WORK}/prune-locked.log"
kill "$holder"
wait "$holder" 2> /dev/null
runuser -u unipept -- mv "${DATA}/current" "${DATA}/current.away"
prune "${WORK}/prune-nocurrent.log" --keep 0
check "without a current link it stops" "$rc" "2"
check_true "and says which version this host serves is not known" grep -q 'not known' "${WORK}/prune-nocurrent.log"
check "and removes nothing" "$(status_of uniprot_entries-2026-09)" "open"
runuser -u unipept -- mv "${DATA}/current.away" "${DATA}/current"
"${REPO}/.deploy/prune.sh" --output-dir "$DATA" --opensearch-url "$OPENSEARCH_URL" --keep 0 > /dev/null 2>&1
check "as root it stops" "$?" "2"


section ".deploy/switch.sh"
# A host that runs the API, as the user it runs as. Four versions: the one it serves, the one it
# switches to, one whose proteins are not loaded, and one loaded ahead of a later switch. The API's
# deploy.sh, sudo and systemctl are stand-ins that record their calls; OpenSearch is the real one,
# and stays up, since the stand-in systemctl only records a stop.
SW=/tmp/switch
SW_DATA="${SW}/data"
SW_STATE="${SW}/state"
SW_BIN="${SW}/bin"
rm -rf "${SW:?}"
mkdir -p "$SW_STATE" "$SW_BIN"
chmod 777 "$SW_STATE"
for version in 2027-01 2027-02 2027-03 2027-04; do
    index_dir="${SW_DATA}/uniprot-${version}/suffix-array"
    mkdir -p "${index_dir}/datastore"
    printf '%s\n' "${version/-/.}" > "${index_dir}/.version"
    for file in sa.bin proteins.bin mapping.bin kmer_table.bin datastore/sampledata.json \
        datastore/{taxons,lineages,interpro_entries,go_terms,ec_numbers,proteomes}.tsv; do
        printf 'x\n' > "${index_dir}/${file}"
    done
done
ln -s uniprot-2027-01 "${SW_DATA}/current"
chown -R -h unipept: "$SW_DATA"
load_version uniprot_entries-2027-01 P27001
load_version uniprot_entries-2027-02 P27002
load_version uniprot_entries-2027-04 P27004
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2027-02/_close" > /dev/null
printf 'INDEX_LOCATION=%s/current/suffix-array\n' "$SW_DATA" > "${SW}/api.env"
chmod 644 "${SW}/api.env"

cat > "${SW_BIN}/deploy.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${SW_STATE}/api-calls"
case "\${1:-}" in
    '')
        if [ -e "${SW_STATE}/old-api" ]; then echo 'usage: deploy.sh deploy' 1>&2; else echo 'usage: deploy.sh stop / deploy.sh start' 1>&2; fi
        exit 2 ;;
    check) [ ! -e "${SW_STATE}/check-fails" ] || { echo 'check: the variant does not fit' 1>&2; exit 1; } ;;
    start)
        [ ! -e "${SW_STATE}/start-sleeps" ] || sleep 3
        [ ! -e "${SW_STATE}/start-fails-once" ] || { rm -f "${SW_STATE}/start-fails-once"; exit 1; }
        [ ! -e "${SW_STATE}/start-fails" ] || exit 1
        readlink "${SW_DATA}/current" > "${SW_STATE}/started-on" ;;
esac
STUB
cat > "${SW_BIN}/sudo" <<STUB
#!/usr/bin/env bash
[ "\$1" != -n ] || shift
if [ "\$1" = -l ]; then [ ! -e "${SW_STATE}/no-sudo" ]; exit; fi
exec "\$@"
STUB
cat > "${SW_BIN}/systemctl" <<STUB
#!/usr/bin/env bash
[ "\$1" = is-active ] || printf '%s\n' "\$*" >> "${SW_STATE}/systemctl-calls"
case "\$1" in
    stop) touch "${SW_STATE}/opensearch-stopped" ;;
    start)
        [ ! -e "${SW_STATE}/opensearch-start-fails-once" ] || { rm -f "${SW_STATE}/opensearch-start-fails-once"; exit 1; }
        rm -f "${SW_STATE}/opensearch-stopped" ;;
    is-active) [ ! -e "${SW_STATE}/opensearch-stopped" ] ;;
esac
STUB
chmod 755 "$SW_BIN"/*

forget_switch_calls() { rm -f "${SW_STATE:?}/api-calls" "${SW_STATE:?}/systemctl-calls" "${SW_STATE:?}/started-on"; }
switch() {
    local logfile=$1
    shift
    forget_switch_calls
    runuser -u unipept -- env PATH="${SW_BIN}:${PATH}" API_ENV_FILE="${SW}/api.env" API_DEPLOY="${SW_BIN}/deploy.sh" API_BINARY="$API_BIN" \
        "${REPO}/.deploy/switch.sh" --output-dir "$SW_DATA" --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}
calls() { tr '\n' ' ' < "${SW_STATE}/$1" 2> /dev/null; }
serves() { readlink "${SW_DATA}/current"; }

# Every problem at once, and nothing stopped for any of them.
printf 'INDEX_LOCATION=%s/uniprot-2027-01/suffix-array\n' "$SW_DATA" > "${SW}/api.env"
touch "${SW_STATE}/no-sudo" "${SW_STATE}/old-api"
switch "${WORK}/switch-refused.log" --uniprot-version 2027-03
check "a host that cannot switch stops it" "$rc" "2"
check_true "its proteins not loaded" grep -q 'uniprot_entries-2027-03 is not in OpenSearch. Load it with load.sh --uniprot-version 2027-03' "${WORK}/switch-refused.log"
check_true "an API that would not follow" grep -q "Set it to ${SW_DATA}/current/suffix-array" "${WORK}/switch-refused.log"
check_true "no sudo for OpenSearch" grep -q 'may not stop and start OpenSearch through sudo' "${WORK}/switch-refused.log"
check_true "an API without stop and start" grep -q 'has no stop and start' "${WORK}/switch-refused.log"
check_true "counted" grep -q '4 problem(s), so nothing was changed' "${WORK}/switch-refused.log"
check "nothing is stopped" "$(calls api-calls)$(calls systemctl-calls)" " "
check "it serves what it served" "$(serves)" "uniprot-2027-01"
printf 'INDEX_LOCATION=%s/current/suffix-array\n' "$SW_DATA" > "${SW}/api.env"
rm -f "${SW_STATE:?}/no-sudo" "${SW_STATE:?}/old-api"

echo 2.6.0 > /tmp/api-bin/version
switch "${WORK}/switch-oldapi.log" --uniprot-version 2027-02
check "an API that queries no version's own index stops it" "$rc" "2"
check_true "and says which is needed" grep -q 'the API installed is 2.6.0, older than 2.7.0' "${WORK}/switch-oldapi.log"
echo 2.7.0-rc.1 > /tmp/api-bin/version
switch "${WORK}/switch-rc.log" --uniprot-version 2027-02 --check
check_true "a release candidate of 2.7.0 is taken for 2.7.0" not_in 'older than' "${WORK}/switch-rc.log"
echo 2.7.0 > /tmp/api-bin/version
mv "$API_BIN" "${API_BIN}.away"
switch "${WORK}/switch-nobinary.log" --uniprot-version 2027-02
check "an API it cannot run stops it" "$rc" "2"
check_true "and says so, not that it is old" grep -q "cannot run ${API_BIN} --version" "${WORK}/switch-nobinary.log"
mv "${API_BIN}.away" "$API_BIN"

curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2027-01/_close" > /dev/null
switch "${WORK}/switch-fromclosed.log" --uniprot-version 2027-02
check "a version it could not go back to stops it" "$rc" "2"
check_true "and says so" grep -q 'uniprot_entries-2027-01, of the version this host serves, is not open' "${WORK}/switch-fromclosed.log"
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2027-01/_open" > /dev/null

switch "${WORK}/switch-nodir.log" --uniprot-version 2027-05
check "a version it does not hold stops it" "$rc" "2"
check_true "and says to copy or build it" grep -q "there is no ${SW_DATA}/uniprot-2027-05. Copy it with clone.sh, or build it" "${WORK}/switch-nodir.log"

mv "${SW_DATA}/uniprot-2027-02/suffix-array/mapping.bin" "${WORK}/mapping.bin.away"
switch "${WORK}/switch-notwhole.log" --uniprot-version 2027-02
check "a version whose files are not whole stops it" "$rc" "2"
check_true "and says it cannot be served" grep -q "FAIL ${SW_DATA}/uniprot-2027-02 is not a database the API can serve" "${WORK}/switch-notwhole.log"
mv "${WORK}/mapping.bin.away" "${SW_DATA}/uniprot-2027-02/suffix-array/mapping.bin"

switch "${WORK}/switch-noopensearch.log" --uniprot-version 2027-02 --opensearch-url http://localhost:1
check "an OpenSearch that does not answer stops it" "$rc" "2"
check_true "and says so" grep -q 'FAIL OpenSearch does not answer at http://localhost:1, so whether uniprot_entries-2027-02 is there is unknown' "${WORK}/switch-noopensearch.log"

# A load of the version that did not finish: its index there, without the mark of a whole one.
curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries-2027-02/_mapping" -H 'Content-Type: application/json' \
    -d '{"_meta":{"unipept_load":"partial"}}' > /dev/null
switch "${WORK}/switch-partial.log" --uniprot-version 2027-02
check "a version whose load did not finish stops it" "$rc" "2"
check_true "and says to continue or redo it" grep -q 'FAIL uniprot_entries-2027-02 was not loaded to the end' "${WORK}/switch-partial.log"
curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries-2027-02/_mapping" -H 'Content-Type: application/json' \
    -d '{"_meta":{"unipept_load":"complete"}}' > /dev/null

touch "${SW_STATE}/check-fails"
switch "${WORK}/switch-apicheck.log" --uniprot-version 2027-02
check "the API's own check refusing stops it" "$rc" "2"
check_true "with the API's reason" grep -q 'check: the variant does not fit' "${WORK}/switch-apicheck.log"
check "nothing is stopped" "$(calls api-calls)" " check --index ${SW_DATA}/uniprot-2027-02/suffix-array "
rm -f "${SW_STATE:?}/check-fails"

# A load holds the lock shared, as load.sh takes it, from before it drops its index to its end. One
# process that holds it, so killing it releases it: runuser would not pass the signal on, and setpriv
# replaces itself. As unipept, as a load runs: /run/lock is sticky, and even root may not open a file
# another user owns there. The lock is one per host, wherever the databases are.
LOCK=/run/lock/unipept-opensearch.lock
mkdir -p /run/lock
chmod 1777 /run/lock
runuser -u unipept -- touch "$LOCK"
# shellcheck disable=SC2016 # $1 belongs to the inner shell
setpriv --reuid unipept --regid unipept --init-groups bash -c 'exec 9>> "$1"; flock -s 9; exec sleep 30' _ "$LOCK" &
loader=$!
for _ in $(seq 50); do
    runuser -u unipept -- flock -n -x "$LOCK" true 2> /dev/null || break
    sleep 0.1
done
switch "${WORK}/switch-loading.log" --uniprot-version 2027-02
check "a load running stops it" "$rc" "2"
check_true "and says so" grep -q 'is running on this host; wait for it to finish' "${WORK}/switch-loading.log"
kill "$loader"
wait "$loader" 2> /dev/null

# A lock it cannot open is said to be that, not taken for a load.
mv "$LOCK" "${LOCK}.away"
touch "$LOCK"
chmod 600 "$LOCK"
switch "${WORK}/switch-lockopen.log" --uniprot-version 2027-02
check "a lock it cannot open stops it" "$rc" "2"
check_true "and says so" grep -q "cannot open the lock ${LOCK} as unipept" "${WORK}/switch-lockopen.log"
check_true "not that another is running" not_in 'is running on this host; wait for it to finish' "${WORK}/switch-lockopen.log"
mv "${LOCK}.away" "$LOCK"

# The links are moved with both stopped, so what would stop that is found before.
chmod 555 "$SW_DATA"
switch "${WORK}/switch-readonly.log" --uniprot-version 2027-02
check "an output directory it cannot write stops it" "$rc" "2"
check_true "and says so" grep -q "${SW_DATA} is not writable by unipept" "${WORK}/switch-readonly.log"
chmod 755 "$SW_DATA"
mkdir "${SW_DATA}/previous"
switch "${WORK}/switch-previousdir.log" --uniprot-version 2027-02
check "a previous that is not a link stops it" "$rc" "2"
check_true "and says so" grep -q 'previous is there and is not a link' "${WORK}/switch-previousdir.log"
rmdir "${SW_DATA}/previous"

# A closed index is only opened once nothing else stands in the way. The refusal of the API's check
# above opened it, as it would: closed again.
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2027-02/_close" > /dev/null
touch "${SW_STATE}/no-sudo"
switch "${WORK}/switch-closed-refused.log" --uniprot-version 2027-02
check "a refused switch" "$rc" "2"
check "leaves the closed index closed" "$(status_of uniprot_entries-2027-02)" "close"
rm -f "${SW_STATE:?}/no-sudo"

switch "${WORK}/switch-check-closed.log" --uniprot-version 2027-02 --check
check "--check on a closed index stops it" "$rc" "2"
check_true "and says the API's check could not run" grep -q "the API's own check of 2027-02 cannot run" "${WORK}/switch-check-closed.log"
check "changing nothing" "$(serves) $(status_of uniprot_entries-2027-02)" "uniprot-2027-01 close"
check "the API's check is not asked" "$(calls api-calls)" " "

curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2027-02/_open" > /dev/null
switch "${WORK}/switch-check.log" --uniprot-version 2027-02 --check
check "--check succeeds" "$rc" "0"
check_true "and says the host can switch" grep -q 'can switch from 2027-01 to 2027-02' "${WORK}/switch-check.log"
check "asking the API's check" "$(calls api-calls)" " check --index ${SW_DATA}/uniprot-2027-02/suffix-array "
check "changing nothing" "$(serves)" "uniprot-2027-01"
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2027-02/_close" > /dev/null

switch "${WORK}/switch.log" --uniprot-version 2027-02
check "a switch succeeds" "$rc" "0"
check "the API checks the new version, is stopped and started" "$(calls api-calls)" " check --index ${SW_DATA}/uniprot-2027-02/suffix-array stop start "
check "OpenSearch is stopped after it and started before it" "$(calls systemctl-calls)" "stop opensearch start opensearch "
check "the API starts on the new version" "$(cat "${SW_STATE}/started-on")" "uniprot-2027-02"
check "current points at it" "$(serves)" "uniprot-2027-02"
check "previous at the one it left" "$(readlink "${SW_DATA}/previous")" "uniprot-2027-01"
check "the links belong to the user the API runs as" "$(stat -c %U "${SW_DATA}/current") $(stat -c %U "${SW_DATA}/previous")" "unipept unipept"
check "its closed index was opened" "$(status_of uniprot_entries-2027-02)" "open"
check "the one it left stays open, to go back to" "$(status_of uniprot_entries-2027-01)" "open"
check "one loaded ahead stays open" "$(status_of uniprot_entries-2027-04)" "open"
check "older ones are closed" "$(status_of uniprot_entries-2026-09)" "close"
check "no alias of the old name is left, which the API no longer queries" "$(alias_target)" ""

switch "${WORK}/switch-again.log" --uniprot-version 2027-02
check "switching to what it serves succeeds" "$rc" "0"
check_true "and says so" grep -q 'already serves 2027-02' "${WORK}/switch-again.log"
check "stopping nothing" "$(calls api-calls)" ""

# previous pointing at a path, as migrate.sh leaves where the version is outside OUTPUT_DIR.
runuser -u unipept -- ln -sfn "${SW_DATA}/uniprot-2027-01" "${SW_DATA}/previous"
switch "${WORK}/switch-back.log" --back
check "--back succeeds" "$rc" "0"
check "back on the one before, where previous pointed" "$(serves) $(readlink "${SW_DATA}/previous")" "${SW_DATA}/uniprot-2027-01 uniprot-2027-02"
runuser -u unipept -- ln -sfn uniprot-2027-01 "${SW_DATA}/current"

# With an older API to roll back to, which after a switch would serve the new files with the proteins
# of the version before it: refused, with how to give that rollback up.
roll_back_to 2.6.0
switch "${WORK}/switch-oldprevious.log" --uniprot-version 2027-02
check "a switch with an older API to roll back to stops it" "$rc" "2"
check_true "and says how to give that rollback up" grep -q "Remove it, as unipept, to give up rolling back past 2.7.0: rm ${API_BIN}.previous" "${WORK}/switch-oldprevious.log"
check "nothing is switched" "$(serves)" "uniprot-2027-01"
roll_back_to 2.7.0
switch "${WORK}/switch-newprevious.log" --uniprot-version 2027-02 --check
check "one that queries versioned indices is fine" "$rc" "0"
rm -f "${API_BIN}.previous"

touch "${SW_STATE}/start-fails-once"
switch "${WORK}/switch-apifails.log" --uniprot-version 2027-02
check "an API that does not start on the new version fails it" "$rc" "2"
check_true "and says the host is back on the old one" grep -q 'This host is back on 2027-01, and serves it' "${WORK}/switch-apifails.log"
check "current points back" "$(serves)" "uniprot-2027-01"
check "and previous too" "$(readlink "${SW_DATA}/previous")" "uniprot-2027-02"
check "the API was started again on the old one" "$(cat "${SW_STATE}/started-on")" "uniprot-2027-01"

touch "${SW_STATE}/opensearch-start-fails-once"
switch "${WORK}/switch-osfails.log" --uniprot-version 2027-02
check "OpenSearch not starting fails it" "$rc" "2"
check_true "and says the host is back" grep -q 'This host is back on 2027-01, and serves it' "${WORK}/switch-osfails.log"
check "OpenSearch was started again" "$(calls systemctl-calls)" "stop opensearch start opensearch start opensearch "
check "current points back" "$(serves)" "uniprot-2027-01"

# A link that cannot be moved once both are stopped: switched back, and both started again.
mkdir "${SW_DATA}/current.new"
switch "${WORK}/switch-nolink.log" --uniprot-version 2027-02
check "a link it cannot move fails it" "$rc" "2"
check_true "and says the host is back" grep -q 'This host is back on 2027-01, and serves it' "${WORK}/switch-nolink.log"
check "the API was started again" "$(cat "${SW_STATE}/started-on")" "uniprot-2027-01"
rmdir "${SW_DATA}/current.new"

touch "${SW_STATE}/start-fails"
switch "${WORK}/switch-bothfail.log" --uniprot-version 2027-02
check "a host that cannot go back either fails it" "$rc" "2"
check_true "and says it needs attention" grep -q 'going back to 2027-01 did too (above): this host needs attention' "${WORK}/switch-bothfail.log"
check "current points back all the same" "$(serves)" "uniprot-2027-01"
rm -f "${SW_STATE:?}/start-fails"

# An interrupt while the API starts on the new version: it goes back.
touch "${SW_STATE}/start-sleeps"
forget_switch_calls
runuser -u unipept -- env PATH="${SW_BIN}:${PATH}" API_ENV_FILE="${SW}/api.env" API_DEPLOY="${SW_BIN}/deploy.sh" API_BINARY="$API_BIN" \
    "${REPO}/.deploy/switch.sh" --output-dir "$SW_DATA" --opensearch-url "$OPENSEARCH_URL" --uniprot-version 2027-02 \
    > "${WORK}/switch-interrupted.log" 2>&1 &
switcher=$!
for _ in $(seq 100); do
    grep -q 'Starting the API' "${WORK}/switch-interrupted.log" && break
    sleep 0.1
done
# To switch.sh itself, as a Ctrl-C or a dropped ssh session reaches it: runuser does not pass a
# TERM on. The script is runuser's child, which env became.
for process in /proc/[0-9]*; do
    [ "$(awk '{ print $4 }' "${process}/stat" 2> /dev/null)" = "$switcher" ] && { kill -TERM "${process#/proc/}"; break; }
done
wait "$switcher"
rc=$?
rm -f "${SW_STATE:?}/start-sleeps"
check "an interrupted switch fails" "$rc" "2"
check_true "and says so" grep -q 'Interrupted' "${WORK}/switch-interrupted.log"
check "current points back" "$(serves)" "uniprot-2027-01"
check "and the API was started on it" "$(cat "${SW_STATE}/started-on")" "uniprot-2027-01"

mv "${SW_DATA}/current" "${SW}/current.away"
switch "${WORK}/switch-nocurrent.log" --uniprot-version 2027-02
check "a host without current stops it" "$rc" "2"
check_true "and says migrate.sh sets it up" grep -q 'Run migrate.sh once' "${WORK}/switch-nocurrent.log"
mv "${SW}/current.away" "${SW_DATA}/current"

"${REPO}/.deploy/switch.sh" --output-dir "$SW_DATA" --uniprot-version 2027-02 > /dev/null 2>&1
check "as root it stops" "$?" "2"


section "the proteins of the version a host serves, kept in the index named after it"
ensure() {
    ( source "${REPO}/pipelines/lib/common.sh" && source "${REPO}/opensearch/lib.sh" && ensure_versioned_index "$1" 60 ) > "${WORK}/ensure.log" 2>&1
    rc=$?
}
ready() {
    ( source "${REPO}/pipelines/lib/common.sh" && source "${REPO}/opensearch/lib.sh" && OPENSEARCH_URL="$1" index_ready "$2" 1 ) > /dev/null 2>&1
}
check_true "an index that answers is ready" ready "$OPENSEARCH_URL" uniprot_entries-2027-01
check_true "one that is not there is not" not_ready "$OPENSEARCH_URL" uniprot_entries-2099-01
check_true "nor is one where OpenSearch does not answer" not_ready http://127.0.0.1:1 uniprot_entries-2027-01
check_true "nor one whose request OpenSearch answers with an error" not_ready "${OPENSEARCH_URL}/no-such-path" uniprot_entries-2027-01
is_marked() { curl -s "${OPENSEARCH_URL}/$1/_mapping" | grep -qF '"unipept_load":"complete"'; }

ensure 2027-01
check "an index already there is left as it is" "$rc" "0"
check "without a word" "$(cat "${WORK}/ensure.log")" ""

# What an interrupted run leaves: the clone, and the block on what it was cloned from.
load_version uniprot_entries-legacy P00007
curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries-legacy/_settings" -H 'Content-Type: application/json' \
    -d '{"index.blocks.write":true}' > /dev/null
ensure 2027-01
check "run again, it succeeds" "$rc" "0"
check "and lifts the block" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${OPENSEARCH_URL}/uniprot_entries-legacy/_doc/P00098" -H 'Content-Type: application/json' -d '{"uniprot_accession_number":"P00098"}')" "201"
curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries-legacy" > /dev/null

curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2027-01/_close" > /dev/null
ensure 2027-01
check "one that is closed" "$rc" "0"
check "is opened" "$(status_of uniprot_entries-2027-01)" "open"

curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries-2027-05" -H 'Content-Type: application/json' \
    -d @"${REPO}/opensearch/mappings/uniprot_entries.json" > /dev/null
ensure 2027-05
check "one that was not loaded to the end fails it" "$rc" "2"
check_true "and says to load it again" grep -q 'uniprot_entries-2027-05 is there and was not loaded to the end' "${WORK}/ensure.log"
curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries-2027-05" > /dev/null

# A host whose alias points at the old index an earlier release kept. The index uniprot_entries the
# first sections loaded goes first: an alias cannot share its name.
curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries" > /dev/null
load_version uniprot_entries-legacy P00001 P00002
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"add":{"index":"uniprot_entries-legacy","alias":"uniprot_entries"}}]}' > /dev/null
ensure 2025-04
check "the proteins behind the alias are kept" "$rc" "0"
check "under the version's name" "$(documents_in uniprot_entries-2025-04)" "2"
check_true "marked as loaded to the end" is_marked uniprot_entries-2025-04
check_true "and it says so" grep -q 'Kept uniprot_entries-legacy as uniprot_entries-2025-04' "${WORK}/ensure.log"
# An alias left on two indices, legacy the second: its proteins are found all the same.
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"add":{"index":"uniprot_entries-2027-01","alias":"uniprot_entries"}}]}' > /dev/null
ensure 2025-05
check "legacy among two the alias points at is found" "$rc" "0"
check "and kept" "$(documents_in uniprot_entries-2025-05)" "2"
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"remove":{"index":"uniprot_entries-2027-01","alias":"uniprot_entries"}}]}' > /dev/null
check "the clone takes writes, as a load continued with --skip makes" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${OPENSEARCH_URL}/uniprot_entries-2025-04/_doc/P00099" -H 'Content-Type: application/json' -d '{"uniprot_accession_number":"P00099"}')" "201"
check "and so does the index it was made from" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${OPENSEARCH_URL}/uniprot_entries-legacy/_doc/P00099" -H 'Content-Type: application/json' -d '{"uniprot_accession_number":"P00099"}')" "201"

# A host loaded before versioned indices, whose proteins are in uniprot_entries itself.
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"remove":{"index":"uniprot_entries-legacy","alias":"uniprot_entries"}}]}' > /dev/null
load_version uniprot_entries P00003 P00004 P00005
ensure 2025-03
check "the proteins in uniprot_entries are kept" "$rc" "0"
check "under the version's name" "$(documents_in uniprot_entries-2025-03)" "3"
check_true "marked as loaded to the end" is_marked uniprot_entries-2025-03
check "and the index they were in is still there" "$(documents_in uniprot_entries)" "3"

curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries" > /dev/null
ensure 2025-02
check "no index holding them fails it" "$rc" "2"
check_true "and says to load them" grep -q 'no index holds the proteins of 2025-02' "${WORK}/ensure.log"

section ".deploy/migrate.sh"
# A host set up before switch.sh: INDEX_LOCATION names the version's directory itself, and its
# proteins are in the index uniprot_entries.
MIG=/tmp/migrate
rm -rf "${MIG:?}"
mkdir -p "${MIG}/data/uniprot-2024-12/suffix-array"
printf 'INDEX_LOCATION=%s/data/uniprot-2024-12/suffix-array\n' "$MIG" > "${MIG}/api.env"
chown -R unipept: "$MIG"
load_version uniprot_entries P24001 P24002
migrate() {
    local logfile=$1
    shift
    runuser -u unipept -- env API_ENV_FILE="${MIG}/api.env" "${REPO}/.deploy/migrate.sh" \
        --output-dir "${MIG}/data" --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}

migrate "${WORK}/migrate.log" --output-dir "${MIG}/data/"
check "it succeeds" "$rc" "0"
check "current points at the version the API serves" "$(readlink "${MIG}/data/current")" "uniprot-2024-12"
check "and belongs to the user the API runs as" "$(stat -c %U "${MIG}/data/current")" "unipept"
check "the proteins are in the index named after it" "$(documents_in uniprot_entries-2024-12)" "2"
check "what the API reads is not touched" "$(sed -n 's/^INDEX_LOCATION=//p' "${MIG}/api.env")" "${MIG}/data/uniprot-2024-12/suffix-array"
check_true "it says to point INDEX_LOCATION through current" grep -qxF "  INDEX_LOCATION=${MIG}/data/current/suffix-array" "${WORK}/migrate.log"

# With a slash at the end, which names the same directory.
printf 'INDEX_LOCATION=%s/data/current/suffix-array/\n' "$MIG" > "${MIG}/api.env"
migrate "${WORK}/migrate-again.log" --output-dir "${MIG}/data/"
check "a second run succeeds" "$rc" "0"
check_true "and says the host is set up" grep -q 'This host is set up for switch.sh' "${WORK}/migrate-again.log"
check "with nothing left to do" "$(grep -c 'Still to do' "${WORK}/migrate-again.log")" "0"

# Where switch.sh has moved it since, it stays.
runuser -u unipept -- ln -sfn uniprot-2027-01 "${MIG}/data/current"
migrate "${WORK}/migrate-moved.log"
check "a link switch.sh moved is left" "$(readlink "${MIG}/data/current")" "uniprot-2027-01"

# A link to one version, and INDEX_LOCATION naming another: whose proteins are which is not known.
runuser -u unipept -- ln -sfn uniprot-2024-11 "${MIG}/data/current"
printf 'INDEX_LOCATION=%s/data/uniprot-2024-12/suffix-array\n' "$MIG" > "${MIG}/api.env"
migrate "${WORK}/migrate-mismatch.log"
check "current and INDEX_LOCATION naming different versions stop it" "$rc" "2"
check_true "and it says so" grep -q 'current points at 2024-11, and INDEX_LOCATION names 2024-12' "${WORK}/migrate-mismatch.log"
check "cloning nothing" "$(status_of uniprot_entries-2024-11)" ""

runuser -u unipept -- unlink "${MIG}/data/current"
printf 'INDEX_LOCATION=/srv/index\n' > "${MIG}/api.env"
migrate "${WORK}/migrate-noversion.log"
check "an INDEX_LOCATION that names no version stops it" "$rc" "2"
check_true "and says how to set it up by hand" grep -q "Point ${MIG}/data/current at it yourself" "${WORK}/migrate-noversion.log"
check_true "setting up no link" test ! -L "${MIG}/data/current"

mv "${MIG}/api.env" "${MIG}/api.env.away"
migrate "${WORK}/migrate-noapi.log"
check "a host without the API stops it" "$rc" "2"
check_true "and says so" grep -q 'this host runs no API' "${WORK}/migrate-noapi.log"
mv "${MIG}/api.env.away" "${MIG}/api.env"

env API_ENV_FILE="${MIG}/api.env" "${REPO}/.deploy/migrate.sh" --output-dir "${MIG}/data" > /dev/null 2>&1
check "as root it stops" "$?" "2"

# A switch or a prune holds the lock; cloning under either could lose what it clones from.
# shellcheck disable=SC2016 # $1 belongs to the inner shell
setpriv --reuid unipept --regid unipept --init-groups bash -c 'exec 9>> "$1"; flock -s 9; exec sleep 30' _ /run/lock/unipept-opensearch.lock &
holder=$!
for _ in $(seq 50); do
    runuser -u unipept -- flock -n -x /run/lock/unipept-opensearch.lock true 2> /dev/null || break
    sleep 0.1
done
migrate "${WORK}/migrate-locked.log"
check "a load, a switch or a prune running stops it" "$rc" "2"
check_true "and says so" grep -q 'is running on this host; wait for it to finish' "${WORK}/migrate-locked.log"
kill "$holder"
wait "$holder" 2> /dev/null

# A clone OpenSearch refuses leaves no write block on what it would have been made from.
ensure 2099-ZZ
check "a clone that is refused fails it" "$rc" "2"
check "and uniprot_entries takes writes again" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${OPENSEARCH_URL}/uniprot_entries/_doc/P00097" -H 'Content-Type: application/json' -d '{"uniprot_accession_number":"P00097"}')" "201"


section ".deploy/prune.sh keeps what an alias of the old name points at"
# A host an earlier release left with the alias on uniprot_entries-legacy, whose API is still from
# before versioned indices and queries through it.
curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries" > /dev/null
[ -n "$(status_of uniprot_entries-legacy)" ] || load_version uniprot_entries-legacy P00001
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"add":{"index":"uniprot_entries-legacy","alias":"uniprot_entries"}}]}' > /dev/null
prune "${WORK}/prune-alias.log" --keep 0
check_true "it succeeds" [ "$rc" -eq 0 ]
check_true "and counts what the alias points at as served" grep -q 'This host serves 2026-07 legacy' "${WORK}/prune-alias.log"
check "that index is kept, though --keep is 0" "$(status_of uniprot_entries-legacy)" "open"


section "a host serves what an alias of the old name points at"
# An API from before versioned indices queries through the alias, whatever INDEX_LOCATION and
# current say: load.sh, build.sh and clone.sh leave that version alone too.
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"remove":{"index":"*","alias":"uniprot_entries"}},{"add":{"index":"uniprot_entries-2027-02","alias":"uniprot_entries"}}]}' > /dev/null
served() {
    local url="$OPENSEARCH_URL"
    ( source "${REPO}/.deploy/lib.sh" && OPENSEARCH_URL="$url" OUTPUT_DIR=/nonexistent API_ENV_FILE=/nonexistent is_served "$1" ) > /dev/null 2>&1
}
check_true "the version it points at is served" served 2027-02
check_true "another is not" not_served 2027-01

# shellcheck disable=SC2031 # the suite's own, which served() only changes in its subshell
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"add":{"index":"uniprot_entries-2027-04","alias":"uniprot_entries"}}]}' > /dev/null
check_true "on two indices, the one" served 2027-02
check_true "and the other" served 2027-04

# shellcheck disable=SC2030 # in the subshell only, on purpose
check "an alias OpenSearch does not answer for fails the question" \
    "$( ( source "${REPO}/.deploy/lib.sh" && OPENSEARCH_URL=http://127.0.0.1:1 OUTPUT_DIR=/nonexistent API_ENV_FILE=/nonexistent served_versions ) > /dev/null 2>&1; echo $?)" "1"


summary
