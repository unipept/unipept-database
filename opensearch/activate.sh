#! /usr/bin/env bash

set -eo pipefail

# Points the uniprot_entries alias, the name the API queries, at one loaded index. The index it
# pointed at before is closed, not deleted, so going back is another run of this script. Nothing is
# deleted here at all: .deploy/prune.sh removes old versions, their indices and their files together.
#
# Flow:
#   1. Check that OpenSearch answers, and that the index to activate is there, open, not empty, and
#      marked by opensearch/load.sh as loaded to the end.
#   2. Where uniprot_entries is still an index rather than an alias, as a host loaded before
#      versioned indices has it, clone it to uniprot_entries-legacy first. A clone is hard links,
#      so it costs no copy, and the first switch then has something to go back to. The old index is
#      marked as loaded to the end before it is cloned: the API was serving it, so it was whole.
#   3. Switch the alias in one request: remove it from the index it named, or remove the old index
#      itself, and add it to the new one. OpenSearch applies the actions of one request together,
#      so the API never finds the name missing.
#   4. Close the index the alias left, which frees the memory it holds and keeps its data.

CURRENT_LOCATION="${BASH_SOURCE%/*}"

source "${CURRENT_LOCATION}/../pipelines/lib/common.sh"
source "${CURRENT_LOCATION}/lib.sh"

OPENSEARCH_URL="http://localhost:9200"

# The index to point the alias at.
INDEX_NAME=""

# Seconds to wait for an index that was opened or cloned to be ready to serve: its primary started,
# which is all a single node can offer.
readonly READY_TIMEOUT=120

trap errorAndExit ERR

print_help() {
    echo "Usage: $0 --index-name NAME [OPTIONS]"
    echo ""
    echo "Points the ${ALIAS} alias at NAME, and closes the index it pointed at before."
    echo ""
    echo "Options:"
    echo "  --index-name        The loaded index to activate, for example ${ALIAS}-2026-03 (required)."
    echo "  --opensearch-url    URL of the OpenSearch instance (optional, default: 'http://localhost:9200')."
    echo "  --help              Prints this help message."
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --index-name) INDEX_NAME="$2"; shift 2 ;;
            --opensearch-url) OPENSEARCH_URL="$2"; shift 2 ;;
            --help) print_help; exit 0 ;;
            *) echo "Unknown parameter: $1" 1>&2; print_help; exit 1 ;;
        esac
    done

    [[ "$INDEX_NAME" == "${ALIAS}-"* ]] || {
        echo "Error: --index-name takes an index named ${ALIAS}-<something>, not '${INDEX_NAME}'." 1>&2
        exit 1
    }
}

wait_until_ready() {
    local health
    # A wait that runs out answers 408, with timed_out in its body.
    health=$(opensearch_request "waiting for $1" "200 408" GET "_cluster/health/$1?wait_for_status=yellow&timeout=${READY_TIMEOUT}s")
    [[ "$health" != *'"timed_out":true'* ]] || opensearch_fail "$1 was not ready within ${READY_TIMEOUT} seconds."
}

parse_arguments "$@"
require_opensearch

status=$(index_status "$INDEX_NAME")
[[ -n "$status" ]] || opensearch_fail "there is no index ${INDEX_NAME} to activate. Load it with load.sh first."

if [[ "$status" == close ]]; then
    opensearch_request "opening ${INDEX_NAME}" "200" POST "${INDEX_NAME}/_open" > /dev/null
    wait_until_ready "$INDEX_NAME"
    log "Opened ${INDEX_NAME}, which was kept closed."
fi

opensearch_request "refreshing ${INDEX_NAME}" "200" POST "${INDEX_NAME}/_refresh" > /dev/null
documents=$(curl -s "${OPENSEARCH_URL}/_cat/count/${INDEX_NAME}?h=count" | awk '{print $NF}')
[[ "${documents:-0}" -gt 0 ]] \
    || opensearch_fail "${INDEX_NAME} holds no documents, so the API would find no protein. Load it again."
# A load that stopped part way leaves documents too.
is_complete "$INDEX_NAME" \
    || opensearch_fail "${INDEX_NAME} was not loaded to the end. Continue its load with --skip, or load it again."

current=$(alias_target)
add=$(alias_add_action "$INDEX_NAME")

if [[ "$current" == "$INDEX_NAME" ]]; then
    # Nothing moves, so nothing is closed: the index kept to go back to stays as it is.
    log "${ALIAS} already points at ${INDEX_NAME}."
    exit 0
elif [[ -n "$(index_status "$ALIAS")" ]]; then
    # A host loaded before versioned indices. The clone needs the source to take no writes, which
    # the API, only reading, does not notice, and carries the mark over with the mapping. A clone
    # that is already there is one an earlier run made and did not get to switch the alias after,
    # so it is taken as it is: only a copy of this index carries the mark under that name.
    if [[ -z "$(index_status "$LEGACY")" ]]; then
        mark_complete "$ALIAS"
        opensearch_request "blocking writes to ${ALIAS}" "200" PUT "${ALIAS}/_settings" \
            -H 'Content-Type: application/json' -d '{"index.blocks.write":true}' > /dev/null
        # No replica, whatever the old index asked for: a single node cannot place one.
        opensearch_request "keeping ${ALIAS} as ${LEGACY}" "200" POST "${ALIAS}/_clone/${LEGACY}" \
            -H 'Content-Type: application/json' -d '{"settings":{"index.number_of_replicas":0}}' > /dev/null
    else
        log "${LEGACY} is there from a switch that did not finish; carrying on from it."
    fi
    wait_until_ready "$LEGACY"
    is_complete "$LEGACY" \
        || opensearch_fail "${LEGACY} is there and is not a copy of ${ALIAS}, so the old index has nowhere to be kept. Delete ${LEGACY} if it is not needed."
    log "${ALIAS} was an index. It is kept as ${LEGACY}."
    previous="$LEGACY"
    actions="{\"remove_index\":{\"index\":\"${ALIAS}\"}},${add}"
elif [[ -n "$current" ]]; then
    previous="$current"
    actions="{\"remove\":{\"index\":\"${current}\",\"alias\":\"${ALIAS}\"}},${add}"
else
    previous=''
    actions="$add"
fi

opensearch_request "pointing ${ALIAS} at ${INDEX_NAME}" "200" POST _aliases \
    -H 'Content-Type: application/json' -d "{\"actions\":[${actions}]}" > /dev/null
log "${ALIAS} now points at ${INDEX_NAME}${previous:+, instead of ${previous}}."

if [[ -n "$previous" && "$(index_status "$previous")" == open ]]; then
    opensearch_request "closing ${previous}" "200" POST "${previous}/_close" > /dev/null
    log "Closed ${previous}. Activating it again opens it."
fi
