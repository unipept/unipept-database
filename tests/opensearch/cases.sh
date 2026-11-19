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


not_in() { ! grep -q "$1" "$2"; }

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


section "a versioned index is loaded beside another"
load_version uniprot_entries-2026-01 P10001 P10002
check_true "the load succeeds" [ "$rc" -eq 0 ]
check "the versioned index holds its rows" "$(documents_in uniprot_entries-2026-01)" "2"
check "the index beside it is untouched" "$(documents_in uniprot_entries)" "3"
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
"${REPO}/opensearch/load.sh" --opensearch-url http://localhost:1 --index-name uniprot_entries-2026-07 --check-complete 2> "${WORK}/check-silent.log"
check "an OpenSearch that does not answer is an error, not a no" "$?" "2"
check_true "and says so" grep -q 'did not say whether uniprot_entries-2026-07 is loaded to the end' "${WORK}/check-silent.log"

write_fixture "${WORK}/rest.tsv.lz4" "$(row 1 P70001 'First protein')" "$(row 2 P70002 'Second protein')"
load /dev/null --uniprot-entries "${WORK}/rest.tsv.lz4" --index-name uniprot_entries-2026-07 --skip 1
"${REPO}/opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name uniprot_entries-2026-07 --check-complete
check "continued to the end, it is marked" "$?" "0"
curl -s -X POST "${OPENSEARCH_URL}/uniprot_entries-2026-07/_refresh" > /dev/null
check "with every row" "$(documents_in uniprot_entries-2026-07)" "2"

summary
