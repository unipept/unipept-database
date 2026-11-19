# shellcheck shell=bash
#
# The mark of an index loaded to the end, and the requests opensearch/load.sh makes. Needs nothing
# else; the script sets OPENSEARCH_URL. Sourced, never run.

# What an index carries in its mapping's _meta once its last row is in. An index a load left part
# way has documents too, so this is how a whole one is told from it. unipept-apps' Ansible playbooks
# check for the same mark.
readonly COMPLETE_MARK='"unipept_load":"complete"'

# Stops with an error, exit 2. In a subshell it ends only that subshell.
opensearch_fail() {
    echo "Error: $*" 1>&2
    exit 2
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

# Whether OpenSearch answers at all, as a test.
opensearch_answers() {
    curl -s -f --max-time 10 "${OPENSEARCH_URL}/_cluster/health" > /dev/null 2>&1
}

require_opensearch() {
    opensearch_answers \
        || opensearch_fail "OpenSearch is not reachable at ${OPENSEARCH_URL}. Start it and run this again."
}

# open or close for an index of exactly this name, and nothing for anything else. By name, because
# _cat/indices answers for an alias with the indices it points at.
index_status() {
    curl -s "${OPENSEARCH_URL}/_cat/indices/$1?h=index,status&expand_wildcards=all" \
        | awk -v name="$1" '$1 == name { print $2 }' || true
}

# How far a load into an index got, where telling "not whole" from "did not answer" matters:
# complete, incomplete (there, and not marked), missing, or unknown, for an error or no answer at
# all. Not index_status, which says whether an index is open or closed.
load_state() {
    local answer code
    answer=$(curl -s --max-time 30 -w '\n%{http_code}' "${OPENSEARCH_URL}/$1/_mapping" 2> /dev/null) || { echo unknown; return 0; }
    code="${answer##*$'\n'}"
    case $code in
        200) if [[ "$answer" == *"$COMPLETE_MARK"* ]]; then echo complete; else echo incomplete; fi ;;
        404) echo missing ;;
        *) echo unknown ;;
    esac
}

mark_complete() {
    opensearch_request "marking $1 as loaded to the end" "200" PUT "$1/_mapping" \
        -H 'Content-Type: application/json' -d "{\"_meta\":{${COMPLETE_MARK}}}" > /dev/null
}
