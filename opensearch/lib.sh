# shellcheck shell=bash
#
# What the scripts that talk to OpenSearch share: the names, the mark of an index loaded to the end,
# and the requests each of them makes. Sourced, never run, after pipelines/lib/common.sh, by
# opensearch/load.sh, opensearch/activate.sh and .deploy/prune.sh, each of which sets
# OPENSEARCH_URL. unipept-api's deploy calls load.sh and activate.sh rather than this, so their
# flags are the interface and this is not.

# The name the API queries: an alias once activate.sh has switched it, an index on a host loaded
# before versioned indices. activate.sh keeps that old index under LEGACY at its first switch.
readonly ALIAS=uniprot_entries
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly LEGACY="${ALIAS}-legacy"

# What an index carries in its mapping's _meta once its last row is in. An index a load left part
# way has documents too, so this is how activate.sh and a rollout tell a whole one from it.
readonly COMPLETE_MARK='"unipept_load":"complete"'

opensearch_fail() {
    echo "Error: $*" 1>&2
    exit 1
}

# Sends one request, and fails unless OpenSearch answers one of the accepted status codes, given
# separated by spaces. Prints the body.
opensearch_request() {
    local what=$1 accepted=$2 method=$3 path=$4 body status
    shift 4

    body=$(curl -s -w '\n%{http_code}' -X "$method" "${OPENSEARCH_URL}/${path}" "$@") \
        || opensearch_fail "${what}: OpenSearch did not answer at ${OPENSEARCH_URL}."
    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    [[ " ${accepted} " == *" ${status} "* ]] || opensearch_fail "${what} answered ${status}: ${body}"
    printf '%s' "$body"
}

require_opensearch() {
    curl -s -f --max-time 10 "${OPENSEARCH_URL}/_cluster/health" > /dev/null \
        || opensearch_fail "OpenSearch is not reachable at ${OPENSEARCH_URL}. Start it and run this again."
}

# The index the alias points at, or nothing where it is not an alias.
alias_target() {
    curl -s "${OPENSEARCH_URL}/_cat/aliases/${ALIAS}?h=index" | tr -d '[:space:]' || true
}

# open or close for an index of exactly this name, and nothing for anything else. By name, because
# _cat/indices answers for an alias with the indices it points at.
index_status() {
    curl -s "${OPENSEARCH_URL}/_cat/indices/$1?h=index,status&expand_wildcards=all" \
        | awk -v name="$1" '$1 == name { print $2 }' || true
}

# Whether an index carries the mark, open or closed: a closed index still answers for its mapping.
is_complete() {
    curl -s -f "${OPENSEARCH_URL}/$1/_mapping" 2> /dev/null | grep -qF "$COMPLETE_MARK"
}

mark_complete() {
    opensearch_request "marking $1 as loaded to the end" "200" PUT "$1/_mapping" \
        -H 'Content-Type: application/json' -d "{\"_meta\":{${COMPLETE_MARK}}}" > /dev/null
}
