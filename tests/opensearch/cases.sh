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
not_ready() { ! ready "$@"; }

# open, close, or nothing for an index that is not there.
status_of() { curl -s "${OPENSEARCH_URL}/_cat/indices/$1?h=status&expand_wildcards=all" 2> /dev/null | grep -xE 'open|close'; }

activate() {
    local logfile=$1
    shift
    "${REPO}/opensearch/activate.sh" --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}

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


section "the first switch keeps the old index, and carries on from one that stopped part way"
# What a first switch that stopped after cloning leaves: the old index marked and write-blocked,
# and its copy under the legacy name, with the alias not yet switched.
curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries/_mapping" -H 'Content-Type: application/json' \
    -d '{"_meta":{"unipept_load":"complete"}}' > /dev/null
curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries/_settings" -H 'Content-Type: application/json' \
    -d '{"index.blocks.write":true}' > /dev/null
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries/_clone/uniprot_entries-legacy" -H 'Content-Type: application/json' \
    -d '{"settings":{"index.number_of_replicas":0}}' > /dev/null
activate "${WORK}/activate.log" --index-name uniprot_entries-2026-01
check_true "it succeeds" [ "$rc" -eq 0 ]
check_true "carrying on from the copy already made" grep -q 'from a switch that did not finish' "${WORK}/activate.log"
check "uniprot_entries is now an alias for the new index" "$(alias_target)" "uniprot_entries-2026-01"
check "the API's name finds the new rows" "$(documents_in uniprot_entries)" "2"
check "the old index is kept, closed" "$(status_of uniprot_entries-legacy)" "close"
"${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name uniprot_entries-legacy --check-complete
check "and marked as loaded to the end, so going back to it is an ordinary switch" "$?" "0"
# The two requests the API makes, by the name it knows.
check_true "a search through the alias answers" grep -q 'P10001' \
    <<< "$(curl -s "${OPENSEARCH_URL}/uniprot_entries/_search?q=uniprot_accession_number:P10001")"
check_true "a multi-get through the alias answers" grep -q '"found":true' \
    <<< "$(curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries/_mget" -H 'Content-Type: application/json' -d '{"ids":["P10002"]}')"


section "a later switch closes the one it leaves, and deletes nothing"
load_version uniprot_entries-2026-02 P20001
activate /dev/null --index-name uniprot_entries-2026-02
check "the alias moves" "$(alias_target)" "uniprot_entries-2026-02"
check "the one it left is closed" "$(status_of uniprot_entries-2026-01)" "close"
check "the one before that is kept, closed" "$(status_of uniprot_entries-legacy)" "close"

load_version uniprot_entries-2026-03 P30001 P30002 P30003
activate /dev/null --index-name uniprot_entries-2026-03
check "the alias moves again" "$(alias_target)" "uniprot_entries-2026-03"
check "the one it left is closed" "$(status_of uniprot_entries-2026-02)" "close"
check "and so is the one before that" "$(status_of uniprot_entries-2026-01)" "close"

# Nothing moves, so the index kept to go back to, older than the active one, must survive.
activate /dev/null --index-name uniprot_entries-2026-03
check_true "activating the active index again succeeds" [ "$rc" -eq 0 ]
check "and deletes nothing, not even the one kept to go back to" "$(status_of uniprot_entries-2026-02)" "close"


section "an index loaded ahead of a switch is kept"
load_version uniprot_entries-2026-05 P50001
load_version uniprot_entries-2026-04 P40001
activate /dev/null --index-name uniprot_entries-2026-04
check "the alias moves to the one named" "$(alias_target)" "uniprot_entries-2026-04"
check "the newer one is left open for its own switch" "$(status_of uniprot_entries-2026-05)" "open"
check "the one it left is closed" "$(status_of uniprot_entries-2026-03)" "close"
check "the older one is kept, closed" "$(status_of uniprot_entries-2026-02)" "close"


section "going back to the index kept closed"
activate "${WORK}/back.log" --index-name uniprot_entries-2026-03
check_true "it succeeds" [ "$rc" -eq 0 ]
check "the alias points back" "$(alias_target)" "uniprot_entries-2026-03"
check "and finds its rows" "$(documents_in uniprot_entries)" "3"
check "the one it left is closed in turn" "$(status_of uniprot_entries-2026-04)" "close"
check "the newer one is still kept" "$(status_of uniprot_entries-2026-05)" "open"


section "what activation refuses"
activate "${WORK}/missing.log" --index-name uniprot_entries-2030-01
check_true "an index that is not there is refused" [ "$rc" -ne 0 ]
check_true "and named" grep -q 'no index uniprot_entries-2030-01' "${WORK}/missing.log"

curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries-2026-06" -H 'Content-Type: application/json' \
    -d @"${REPO}/opensearch/mappings/uniprot_entries.json" > /dev/null
activate "${WORK}/empty.log" --index-name uniprot_entries-2026-06
check_true "an empty index is refused" [ "$rc" -ne 0 ]
check_true "and said to be empty" grep -q 'holds no documents' "${WORK}/empty.log"
curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries-2026-06" > /dev/null

activate /dev/null --index-name some_other_index
check_true "an index that is not a uniprot_entries one is refused" [ "$rc" -ne 0 ]
check "after all of these the alias is where it was" "$(alias_target)" "uniprot_entries-2026-03"


section "what the loader refuses once uniprot_entries is an alias"
write_fixture "$FIXTURE" "$(row 1 P00001 'First protein')"
load "${WORK}/alias.log" --uniprot-entries "$FIXTURE"
check_true "loading into the alias's name is refused" [ "$rc" -ne 0 ]
check_true "and says to load a versioned index" grep -q 'is an alias' "${WORK}/alias.log"

load "${WORK}/live.log" --uniprot-entries "$FIXTURE" --index-name uniprot_entries-2026-03
check_true "reloading the index the alias points at is refused" [ "$rc" -ne 0 ]
check_true "and says what it would do to the API" grep -q 'empties the API' "${WORK}/live.log"
check "the API's rows are untouched" "$(documents_in uniprot_entries)" "3"

load /dev/null --uniprot-entries "$FIXTURE" --index-name uniprot_entries-2026-03 --replace-live
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2026-03/_refresh" > /dev/null
check_true "--replace-live allows it" [ "$rc" -eq 0 ]
check "the alias still points at it" "$(alias_target)" "uniprot_entries-2026-03"
check "and the API then finds the new rows" "$(documents_in uniprot_entries)" "1"


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

activate "${WORK}/partial.log" --index-name uniprot_entries-2026-07
check_true "activating it is refused" [ "$rc" -ne 0 ]
check_true "and says the load did not finish" grep -q 'not loaded to the end' "${WORK}/partial.log"
check "the alias stays where it was" "$(alias_target)" "uniprot_entries-2026-03"

write_fixture "${WORK}/rest.tsv.lz4" "$(row 1 P70001 'First protein')" "$(row 2 P70002 'Second protein')"
load /dev/null --uniprot-entries "${WORK}/rest.tsv.lz4" --index-name uniprot_entries-2026-07 --skip 1
"${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name uniprot_entries-2026-07 --check-complete
check "continued to the end, it is marked" "$?" "0"
activate /dev/null --index-name uniprot_entries-2026-07
check "and can be activated" "$(alias_target)" "uniprot_entries-2026-07"
check "with every row" "$(documents_in uniprot_entries)" "2"


section ".deploy/prune.sh"
# As the user the .deploy scripts run as, with each version's directory beside its index, the way
# a host holds them. The alias points at uniprot_entries-2026-07 by here, and every version before
# it, legacy included, is still in OpenSearch.
DATA=/tmp/prune-data
rm -rf "$DATA"
for version in 2026-03 2026-04 2026-05 2026-07; do
    mkdir -p "${DATA}/uniprot-${version}/suffix-array"
done
chown -R unipept: "$DATA"

prune() {
    local logfile=$1
    shift
    runuser -u unipept -- "${REPO}/.deploy/prune.sh" --output-dir "$DATA" --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}

prune "${WORK}/prune-dry.log" --keep 2 --dry-run
check_true "a dry run succeeds" [ "$rc" -eq 0 ]
check_true "and names what it would remove, newest first" grep -q 'Removing: 2026-03 2026-02 2026-01 legacy' "${WORK}/prune-dry.log"
check "without removing an index" "$(status_of uniprot_entries-2026-01)" "close"
check_true "or a directory" test -d "${DATA}/uniprot-2026-03"

prune "${WORK}/prune.log" --keep 2
check_true "it succeeds" [ "$rc" -eq 0 ]
check "the version the API queries is kept" "$(alias_target)" "uniprot_entries-2026-07"
check "with its rows" "$(documents_in uniprot_entries)" "2"
check "and its files" "$([ -d "${DATA}/uniprot-2026-07" ] && echo kept)" "kept"
check "the two before it are kept, index and files" \
    "$(status_of uniprot_entries-2026-05) $(status_of uniprot_entries-2026-04) $([ -d "${DATA}/uniprot-2026-04" ] && echo kept)" \
    "open close kept"
check "older ones lose their index" "$(status_of uniprot_entries-2026-03)$(status_of uniprot_entries-2026-01)$(status_of uniprot_entries-legacy)" ""
check "and their files" "$([ -e "${DATA}/uniprot-2026-03" ] && echo left || echo removed)" "removed"

section ".deploy/prune.sh keeps the files the API reads, when its alias has moved on"
# What load.sh --activate leaves until the API's rollout switches its files too: the alias on
# 2026-07, and the API still reading 2026-04.
printf 'INDEX_LOCATION=%s/uniprot-2026-04/suffix-array\n' "$DATA" > /tmp/api.env
chmod 644 /tmp/api.env
prune_as_api() {
    local logfile=$1
    shift
    runuser -u unipept -- env API_ENV_FILE=/tmp/api.env "${REPO}/.deploy/prune.sh" --output-dir "$DATA" \
        --opensearch-url "$OPENSEARCH_URL" "$@" > "$logfile" 2>&1
    rc=$?
}
prune_as_api "${WORK}/prune-served.log" --keep 0
check_true "it succeeds" [ "$rc" -eq 0 ]
check_true "and says what the API reads" grep -q 'reads the files of 2026-04' "${WORK}/prune-served.log"
check "the files the API reads are kept, with their index" "$([ -d "${DATA}/uniprot-2026-04" ] && echo kept) $(status_of uniprot_entries-2026-04)" "kept close"
check "and everything between them and the alias" "$(status_of uniprot_entries-2026-05)" "open"

printf 'INDEX_LOCATION=/srv/index\n' > /tmp/api.env
prune_as_api "${WORK}/prune-noversion.log" --keep 0
check "an INDEX_LOCATION that names no version stops it" "$rc" "2"
check "and removes nothing" "$(status_of uniprot_entries-2026-04)" "close"
chmod 600 /tmp/api.env
prune_as_api "${WORK}/prune-unreadable.log" --keep 0
check "an environment file it cannot read stops it" "$rc" "2"
rm /tmp/api.env


section ".deploy/prune.sh keeps a version loaded ahead of a switch"
load_version uniprot_entries-2026-09 P90001
mkdir -p "${DATA}/uniprot-2026-09/suffix-array" && chown -R unipept: "${DATA}/uniprot-2026-09"
prune "${WORK}/prune-ahead.log" --keep 0
check_true "it succeeds" [ "$rc" -eq 0 ]
check "the newer version is kept, though --keep is 0" "$(status_of uniprot_entries-2026-09) $([ -d "${DATA}/uniprot-2026-09" ] && echo kept)" "open kept"
check "the version the API queries is kept" "$(alias_target)" "uniprot_entries-2026-07"
check "everything older is removed" "$(status_of uniprot_entries-2026-05)$(status_of uniprot_entries-2026-04)" ""
check "files included" "$(find "$DATA" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')" "uniprot-2026-07 uniprot-2026-09 "

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
check_true "and says so" grep -q 'a load or a switch is running on this host' "${WORK}/prune-locked.log"
kill "$holder"
wait "$holder" 2> /dev/null
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"remove":{"index":"uniprot_entries-2026-07","alias":"uniprot_entries"}}]}' > /dev/null
prune "${WORK}/prune-noalias.log" --keep 0
check "without an alias it stops" "$rc" "2"
check_true "and says which version the API queries is not known" grep -q 'not known' "${WORK}/prune-noalias.log"
check "and removes nothing" "$(status_of uniprot_entries-2026-09)" "open"
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"add":{"index":"uniprot_entries-2026-07","alias":"uniprot_entries"}}]}' > /dev/null
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
    runuser -u unipept -- env PATH="${SW_BIN}:${PATH}" API_ENV_FILE="${SW}/api.env" API_DEPLOY="${SW_BIN}/deploy.sh" \
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

switch "${WORK}/switch-nodir.log" --uniprot-version 2027-05
check "a version it does not hold stops it" "$rc" "2"
check_true "and says to copy or build it" grep -q "there is no ${SW_DATA}/uniprot-2027-05. Copy it with clone.sh, or build it" "${WORK}/switch-nodir.log"

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
check_true "and says so" grep -q 'a load is running on this host' "${WORK}/switch-loading.log"
kill "$loader"
wait "$loader" 2> /dev/null

# A lock it cannot open is said to be that, not taken for a load.
mv "$LOCK" "${LOCK}.away"
touch "$LOCK"
chmod 644 "$LOCK"
switch "${WORK}/switch-lockopen.log" --uniprot-version 2027-02
check "a lock it cannot open stops it" "$rc" "2"
check_true "and says so" grep -q "cannot open the lock ${LOCK} as unipept" "${WORK}/switch-lockopen.log"
check_true "not that a load is running" not_in 'a load is running' "${WORK}/switch-lockopen.log"
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
check "the alias of the old name is removed, which the API no longer queries" "$(alias_target)" ""
check_true "and it says so" grep -q 'Removed the alias uniprot_entries' "${WORK}/switch.log"

switch "${WORK}/switch-again.log" --uniprot-version 2027-02
check "switching to what it serves succeeds" "$rc" "0"
check_true "and says so" grep -q 'already serves 2027-02' "${WORK}/switch-again.log"
check "stopping nothing" "$(calls api-calls)" ""

switch "${WORK}/switch-back.log" --back
check "--back succeeds" "$rc" "0"
check "back on the one before" "$(serves) $(readlink "${SW_DATA}/previous")" "uniprot-2027-01 uniprot-2027-02"

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
runuser -u unipept -- env PATH="${SW_BIN}:${PATH}" API_ENV_FILE="${SW}/api.env" API_DEPLOY="${SW_BIN}/deploy.sh" \
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
check "one that was not loaded to the end fails it" "$rc" "1"
check_true "and says to load it again" grep -q 'uniprot_entries-2027-05 is there and was not loaded to the end' "${WORK}/ensure.log"
curl -s -X DELETE "${OPENSEARCH_URL}/uniprot_entries-2027-05" > /dev/null

# A host whose alias points at the old index activate.sh kept.
load_version uniprot_entries-legacy P00001 P00002
curl -s -X POST "${OPENSEARCH_URL}/_aliases" -H 'Content-Type: application/json' \
    -d '{"actions":[{"add":{"index":"uniprot_entries-legacy","alias":"uniprot_entries"}}]}' > /dev/null
ensure 2025-04
check "the proteins behind the alias are kept" "$rc" "0"
check "under the version's name" "$(documents_in uniprot_entries-2025-04)" "2"
check_true "marked as loaded to the end" is_marked uniprot_entries-2025-04
check_true "and it says so" grep -q 'Kept uniprot_entries-legacy as uniprot_entries-2025-04' "${WORK}/ensure.log"
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
check "no index holding them fails it" "$rc" "1"
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

migrate "${WORK}/migrate.log"
check "it succeeds" "$rc" "0"
check "current points at the version the API serves" "$(readlink "${MIG}/data/current")" "uniprot-2024-12"
check "and belongs to the user the API runs as" "$(stat -c %U "${MIG}/data/current")" "unipept"
check "the proteins are in the index named after it" "$(documents_in uniprot_entries-2024-12)" "2"
check "what the API reads is not touched" "$(sed -n 's/^INDEX_LOCATION=//p' "${MIG}/api.env")" "${MIG}/data/uniprot-2024-12/suffix-array"
check_true "it says to point INDEX_LOCATION through current" grep -qxF "  INDEX_LOCATION=${MIG}/data/current/suffix-array" "${WORK}/migrate.log"

# With a slash at the end, which names the same directory.
printf 'INDEX_LOCATION=%s/data/current/suffix-array/\n' "$MIG" > "${MIG}/api.env"
migrate "${WORK}/migrate-again.log"
check "a second run succeeds" "$rc" "0"
check_true "and says the host is set up" grep -q 'This host is set up for switch.sh' "${WORK}/migrate-again.log"
check "with nothing left to do" "$(grep -c 'Still to do' "${WORK}/migrate-again.log")" "0"

# Where switch.sh has moved it since, it stays.
runuser -u unipept -- ln -sfn uniprot-2027-01 "${MIG}/data/current"
migrate "${WORK}/migrate-moved.log"
check "a link switch.sh moved is left" "$(readlink "${MIG}/data/current")" "uniprot-2027-01"

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


summary
