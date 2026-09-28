#! /usr/bin/env bash

set -eo pipefail

# Points the uniprot_entries alias, the name the API queries, at one loaded index. The index it
# pointed at before is kept, closed, so going back is another run of this script; older ones are
# deleted.
#
# Flow:
#   1. Check that OpenSearch answers, and that the index to activate is there, open and not empty.
#   2. Where uniprot_entries is still an index rather than an alias, as a host loaded before
#      versioned indices has it, clone it to uniprot_entries-legacy first. A clone is hard links,
#      so it costs no copy, and the first switch then has something to go back to.
#   3. Switch the alias in one request: remove it from the index it named, or remove the old index
#      itself, and add it to the new one. OpenSearch applies the actions of one request together,
#      so the API never finds the name missing.
#   4. Close the index the alias left, which frees the memory it holds and keeps its data.
#   5. Delete the other uniprot_entries-* indices, except those of a newer version than the one
#      now active, which are loaded ahead of a switch still to come.

CURRENT_LOCATION="${BASH_SOURCE%/*}"

source "${CURRENT_LOCATION}/../pipelines/lib/common.sh"

OPENSEARCH_URL="http://localhost:9200"

# The index to point the alias at.
INDEX_NAME=""

# The name the API queries.
readonly ALIAS="uniprot_entries"

# What a host loaded before versioned indices had, once it is kept under a name of its own.
readonly LEGACY="${ALIAS}-legacy"

# Seconds to wait for an index that was opened or cloned to be ready to serve: its primary started,
# which is all a single node can offer.
readonly READY_TIMEOUT=120

trap errorAndExit ERR

print_help() {
    echo "Usage: $0 --index-name NAME [OPTIONS]"
    echo ""
    echo "Points the ${ALIAS} alias at NAME, closes the index it pointed at before, and deletes older ones."
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

fail() {
    echo "Error: $*" 1>&2
    exit 1
}

# Sends one request and fails unless OpenSearch answers 200. Prints the body.
request() {
    local what=$1 method=$2 path=$3 body status
    shift 3

    body=$(curl -s -w '\n%{http_code}' -X "$method" "${OPENSEARCH_URL}/${path}" "$@") \
        || fail "${what}: OpenSearch did not answer at ${OPENSEARCH_URL}."
    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    [[ "$status" == 200 ]] || fail "${what} answered ${status}: ${body}"
    printf '%s' "$body"
}

# Whether the name is an index, closed or open, as opposed to an alias or nothing.
is_index() {
    curl -s "${OPENSEARCH_URL}/_cat/indices/$1?h=index&expand_wildcards=all" | grep -qxF "$1"
}

# open or close, for an index.
index_status() {
    curl -s "${OPENSEARCH_URL}/_cat/indices/$1?h=status&expand_wildcards=all" | tr -d '[:space:]'
}

wait_until_ready() {
    local health
    health=$(request "waiting for $1" GET "_cluster/health/$1?wait_for_status=yellow&timeout=${READY_TIMEOUT}s")
    [[ "$health" != *'"timed_out":true'* ]] || fail "$1 was not ready within ${READY_TIMEOUT} seconds."
}

# The version in an index name, YYYY-MM, or nothing for a name that holds none.
version_of() {
    local version="${1#"${ALIAS}"-}"
    [[ "$version" =~ ^[0-9]{4}-[0-9]{2}$ ]] && echo "$version"
}

parse_arguments "$@"

curl -s -f "${OPENSEARCH_URL}/_cluster/health" > /dev/null \
    || fail "OpenSearch is not reachable at ${OPENSEARCH_URL}."

is_index "$INDEX_NAME" || fail "there is no index ${INDEX_NAME} to activate. Load it with .deploy/load.sh first."

if [[ "$(index_status "$INDEX_NAME")" == close ]]; then
    request "opening ${INDEX_NAME}" POST "${INDEX_NAME}/_open" > /dev/null
    wait_until_ready "$INDEX_NAME"
    log "Opened ${INDEX_NAME}, which was kept closed."
fi

request "refreshing ${INDEX_NAME}" POST "${INDEX_NAME}/_refresh" > /dev/null
documents=$(curl -s "${OPENSEARCH_URL}/_cat/count/${INDEX_NAME}?h=count" | awk '{print $NF}')
[[ "${documents:-0}" -gt 0 ]] || fail "${INDEX_NAME} holds no documents, so the API would find no protein. Load it again."

current=$(curl -s "${OPENSEARCH_URL}/_cat/aliases/${ALIAS}?h=index" | tr -d '[:space:]')

if [[ "$current" == "$INDEX_NAME" ]]; then
    # Nothing moves, so nothing is closed or deleted: the index kept to go back to stays.
    log "${ALIAS} already points at ${INDEX_NAME}."
    exit 0
elif is_index "$ALIAS"; then
    # A host loaded before versioned indices. The clone needs the source to take no writes, which
    # the API, only reading, does not notice.
    ! is_index "$LEGACY" || fail "${ALIAS} is an index and ${LEGACY} already exists, so the old index has nowhere to be kept. Delete ${LEGACY} if it is not needed."
    request "blocking writes to ${ALIAS}" PUT "${ALIAS}/_settings" \
        -H 'Content-Type: application/json' -d '{"index.blocks.write":true}' > /dev/null
    # No replica, whatever the old index asked for: a single node cannot place one.
    request "keeping ${ALIAS} as ${LEGACY}" POST "${ALIAS}/_clone/${LEGACY}" \
        -H 'Content-Type: application/json' -d '{"settings":{"index.number_of_replicas":0}}' > /dev/null
    wait_until_ready "$LEGACY"
    request "switching ${ALIAS} to an alias for ${INDEX_NAME}" POST _aliases -H 'Content-Type: application/json' \
        -d "{\"actions\":[{\"add\":{\"index\":\"${INDEX_NAME}\",\"alias\":\"${ALIAS}\"}},{\"remove_index\":{\"index\":\"${ALIAS}\"}}]}" > /dev/null
    log "${ALIAS} was an index. It is kept as ${LEGACY}, and ${ALIAS} is now an alias for ${INDEX_NAME}."
    previous="$LEGACY"
elif [[ -n "$current" ]]; then
    request "switching ${ALIAS} from ${current} to ${INDEX_NAME}" POST _aliases -H 'Content-Type: application/json' \
        -d "{\"actions\":[{\"remove\":{\"index\":\"${current}\",\"alias\":\"${ALIAS}\"}},{\"add\":{\"index\":\"${INDEX_NAME}\",\"alias\":\"${ALIAS}\"}}]}" > /dev/null
    log "${ALIAS} now points at ${INDEX_NAME}, instead of ${current}."
    previous="$current"
else
    request "adding ${ALIAS} for ${INDEX_NAME}" POST _aliases -H 'Content-Type: application/json' \
        -d "{\"actions\":[{\"add\":{\"index\":\"${INDEX_NAME}\",\"alias\":\"${ALIAS}\"}}]}" > /dev/null
    log "${ALIAS} now points at ${INDEX_NAME}."
    previous=''
fi

if [[ -n "$previous" && "$(index_status "$previous")" == open ]]; then
    request "closing ${previous}" POST "${previous}/_close" > /dev/null
    log "Closed ${previous}. Activating it again opens it."
fi

active_version=$(version_of "$INDEX_NAME") || true
while read -r index; do
    [[ -n "$index" && "$index" != "$INDEX_NAME" && "$index" != "$previous" ]] || continue
    candidate_version=$(version_of "$index") || true
    # Loaded ahead of a switch still to come.
    if [[ -n "$candidate_version" && -n "$active_version" && "$candidate_version" > "$active_version" ]]; then
        continue
    fi
    request "deleting ${index}" DELETE "$index" > /dev/null
    log "Deleted ${index}. ${previous:-Nothing} is kept to go back to."
done < <(curl -s "${OPENSEARCH_URL}/_cat/indices/${ALIAS}-*?h=index&expand_wildcards=all")
