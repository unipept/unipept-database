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


summary
