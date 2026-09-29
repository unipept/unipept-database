# shellcheck shell=bash
#
# What the scripts that talk to OpenSearch share: the names, the mark of an index loaded to the end,
# and the requests each of them makes. Sourced, never run, after pipelines/lib/common.sh, by
# opensearch/load.sh and the scripts in .deploy that talk to OpenSearch, each of which sets
# OPENSEARCH_URL.

# What every version's index is named after, uniprot_entries-2026-03 for 2026-03, which is the one
# the API queries. A host loaded before versioned indices has its proteins in an index of this name
# itself, or in LEGACY, with an alias of this name on it, where an earlier release of these scripts
# kept them.
readonly ALIAS=uniprot_entries
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly LEGACY="${ALIAS}-legacy"

# What an index carries in its mapping's _meta once its last row is in. An index a load left part
# way has documents too, so this is how switch.sh and the API's check tell a whole one from it.
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

# The index an alias of that name points at, or nothing where there is none.
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

# Waits for an index to be ready to serve: its primary started, which is all a single node offers.
# A wait that runs out answers 408, with timed_out in its body.
wait_until_ready() {
    local index="$1" timeout="$2" health

    health=$(opensearch_request "waiting for ${index}" "200 408" GET "_cluster/health/${index}?wait_for_status=yellow&timeout=${timeout}s")
    [[ "$health" != *'"timed_out":true'* ]] || opensearch_fail "${index} was not ready within ${timeout} seconds."
}

# Keeps a whole index under another name, by a clone: hard links, so no copy. The clone needs the
# source to take no writes, which the API, only reading, does not notice, and it carries the mark
# over with the mapping. The source was served, so it was whole, and is marked as such first.
keep_as() {
    local source="$1" target="$2" timeout="$3"

    mark_complete "$source"
    opensearch_request "blocking writes to ${source}" "200" PUT "${source}/_settings" \
        -H 'Content-Type: application/json' -d '{"index.blocks.write":true}' > /dev/null
    # No replica, whatever the old index asked for: a single node cannot place one.
    opensearch_request "keeping ${source} as ${target}" "200" POST "${source}/_clone/${target}" \
        -H 'Content-Type: application/json' -d '{"settings":{"index.number_of_replicas":0}}' > /dev/null
    wait_until_ready "$target" "$timeout"
}

# Makes sure the proteins of a version are in its own index, uniprot_entries-<version>, which is
# what the API queries. A host loaded before versioned indices has them in uniprot_entries itself,
# or in uniprot_entries-legacy with an alias of that name on it, as an earlier release left it:
# either is kept under the version's name. An index of that name already there has to be whole, and
# is opened where it is closed, as an earlier release closed the one it switched away from. Fails
# where no index holds them, or where the one there is not whole.
ensure_versioned_index() {
    local version="$1" timeout="$2" index="${ALIAS}-${1}" source='' status

    status=$(index_status "$index")
    if [ -n "$status" ]; then
        is_complete "$index" \
            || opensearch_fail "${index} is there and was not loaded to the end. Load it again with load.sh --uniprot-version ${version}, or continue its load with --skip."
        if [ "$status" = close ]; then
            opensearch_request "opening ${index}" "200" POST "${index}/_open" > /dev/null
            wait_until_ready "$index" "$timeout"
            echo "Opened ${index}, which was closed." 1>&2
        fi
        return 0
    fi

    if [ -n "$(index_status "$ALIAS")" ]; then
        source="$ALIAS"
    elif [ "$(alias_target)" = "$LEGACY" ]; then
        source="$LEGACY"
    else
        opensearch_fail "no index holds the proteins of ${version}: ${index} is not there, and ${ALIAS} is not an index or an alias for ${LEGACY}. Load them with load.sh --uniprot-version ${version}."
    fi

    keep_as "$source" "$index" "$timeout"
    echo "Kept ${source} as ${index}, the index the API queries for ${version}." 1>&2
}
