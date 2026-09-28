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


section "the first switch keeps the old index"
activate "${WORK}/activate.log" --index-name uniprot_entries-2026-01
check_true "it succeeds" [ "$rc" -eq 0 ]
check "uniprot_entries is now an alias for the new index" "$(alias_target)" "uniprot_entries-2026-01"
check "the API's name finds the new rows" "$(documents_in uniprot_entries)" "2"
check "the old index is kept, closed" "$(status_of uniprot_entries-legacy)" "close"
# The two requests the API makes, by the name it knows.
check_true "a search through the alias answers" grep -q 'P10001' \
    <<< "$(curl -s "${OPENSEARCH_URL}/uniprot_entries/_search?q=uniprot_accession_number:P10001")"
check_true "a multi-get through the alias answers" grep -q '"found":true' \
    <<< "$(curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries/_mget" -H 'Content-Type: application/json' -d '{"ids":["P10002"]}')"


section "a later switch closes the one it leaves and deletes the one before"
load_version uniprot_entries-2026-02 P20001
activate /dev/null --index-name uniprot_entries-2026-02
check "the alias moves" "$(alias_target)" "uniprot_entries-2026-02"
check "the one it left is closed" "$(status_of uniprot_entries-2026-01)" "close"
check "the one before that is deleted" "$(status_of uniprot_entries-legacy)" ""

load_version uniprot_entries-2026-03 P30001 P30002 P30003
activate /dev/null --index-name uniprot_entries-2026-03
check "the alias moves again" "$(alias_target)" "uniprot_entries-2026-03"
check "the one it left is closed" "$(status_of uniprot_entries-2026-02)" "close"
check "the one before that is deleted" "$(status_of uniprot_entries-2026-01)" ""

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
check "the older one is deleted" "$(status_of uniprot_entries-2026-02)" ""


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


summary
