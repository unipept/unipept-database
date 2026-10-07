# shellcheck shell=bash
#
# What the scripts that talk to OpenSearch share: the names, the mark of an index loaded to the end,
# and the requests each of them makes. Needs nothing else; each script that sources it sets
# OPENSEARCH_URL. Sourced, never run: by opensearch/load.sh, and through .deploy/lib.sh.

# What every version's index is named after, uniprot_entries-2026-03 for 2026-03, which is the one
# the API queries. A host loaded before versioned indices has its proteins in an index of this name
# itself, or in LEGACY, with an alias of this name on it.
readonly ALIAS=uniprot_entries
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly LEGACY="${ALIAS}-legacy"

# What an index carries in its mapping's _meta once its last row is in. An index a load left part
# way has documents too, so this is how switch.sh and the API's check tell a whole one from it.
readonly COMPLETE_MARK='"unipept_load":"complete"'

# Stops with an error, exit 2. Not die: this file needs nothing else, and opensearch/load.sh loads
# it without core.sh. In a subshell it ends only that subshell, which keep_as relies on.
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

# The version an index holds: YYYY-MM for uniprot_entries-YYYY-MM, legacy or plain for what a host
# loaded before versioned indices kept, uniprot_entries-legacy and uniprot_entries itself. Nothing for
# an index that is not a database's.
version_of_index() {
    local version="${1#"${ALIAS}"-}"

    if [ "$1" = "$ALIAS" ]; then
        echo plain
    elif [ "$1" = "$LEGACY" ]; then
        echo legacy
    elif [[ "$version" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "$version"
    fi
}

# Every index an alias of that name points at, one per line, or nothing where there is none. Fails
# where OpenSearch does not answer the question, which is not the same as there being no alias.
alias_targets() {
    local answer
    answer=$(curl -s -f --max-time 10 "${OPENSEARCH_URL}/_cat/aliases/${ALIAS}?h=index") || return 1
    printf '%s\n' "$answer" | awk 'NF { print $1 }'
}

# open or close for an index of exactly this name, and nothing for anything else. By name, because
# _cat/indices answers for an alias with the indices it points at.
index_status() {
    curl -s "${OPENSEARCH_URL}/_cat/indices/$1?h=index,status&expand_wildcards=all" \
        | awk -v name="$1" '$1 == name { print $2 }' || true
}

# Whether an index carries the mark, open or closed: a closed index still answers for its mapping.
is_complete() {
    [ "$(load_state "$1")" = complete ]
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

# Whether an index becomes ready to serve within the timeout: its primary started, which is all a
# single node offers. A test, which fails as well where OpenSearch does not answer the request.
index_ready() {
    local index="$1" timeout="$2" answer

    answer=$(curl -s -w '\n%{http_code}' --max-time "$((timeout + 30))" \
        "${OPENSEARCH_URL}/_cluster/health/${index}?wait_for_status=yellow&timeout=${timeout}s") || return 1
    [ "${answer##*$'\n'}" = 200 ] && [[ "$answer" != *'"timed_out":true'* ]]
}

# index_ready, stopping the script where the index does not become ready.
wait_until_ready() {
    index_ready "$1" "$2" || opensearch_fail "$1 was not ready within $2 seconds."
}

# Keeps a whole index under another name, by a clone: hard links, so no copy. The clone needs the
# source to take no writes, which the API, only reading, does not notice, and it carries the mark
# over with the mapping. The source was served, so it was whole, and is marked as such first.
keep_as() {
    local source="$1" target="$2" timeout="$3"

    mark_complete "$source"
    opensearch_request "blocking writes to ${source}" "200" PUT "${source}/_settings" \
        -H 'Content-Type: application/json' -d '{"index.blocks.write":true}' > /dev/null
    # No replica, whatever the old index asked for: a single node cannot place one. Nor the block the
    # clone needed, which it would otherwise copy: a load continued with --skip writes to it.
    # In a subshell, since a refused request stops the script it is in, and the block has to come off
    # the source first.
    ( opensearch_request "keeping ${source} as ${target}" "200" POST "${source}/_clone/${target}" \
        -H 'Content-Type: application/json' -d '{"settings":{"index.number_of_replicas":0,"index.blocks.write":null}}' > /dev/null ) \
        || { allow_writes "$source"; exit 2; }
    # The clone recovers from the source's files, so the source takes no writes until it is ready,
    # and takes them again whether it becomes ready or not.
    if ! index_ready "$target" "$timeout"; then
        allow_writes "$source"
        opensearch_fail "${target} was not ready within ${timeout} seconds. Delete it, and run this again."
    fi
    allow_writes "$source"
}

# Lifts the write block keep_as puts on an index, where it is there. Quietly: nothing depends on it.
allow_writes() {
    curl -s -o /dev/null -X PUT "${OPENSEARCH_URL}/$1/_settings" \
        -H 'Content-Type: application/json' -d '{"index.blocks.write":null}' || true
}

# Makes sure the proteins of a version are in its own index, uniprot_entries-<version>, which is
# what the API queries. A host loaded before versioned indices has them in uniprot_entries itself,
# or in uniprot_entries-legacy with an alias of that name on it, as some hosts have it: either is
# kept under the version's name. An index of that name already there has to be whole, and is opened
# where it is closed, as switch.sh closes those of versions older than the two it switched between.
# Fails where no index holds them, or where the one there is not whole.
ensure_versioned_index() {
    local version="$1" timeout="$2" index="${ALIAS}-${1}" source='' status

    status=$(index_status "$index")
    if [ -n "$status" ]; then
        is_complete "$index" \
            || opensearch_fail "${index} is there and was not loaded to the end. Load it again with load.sh --uniprot-version ${version}, or continue its load with --skip."
        if [ "$status" = close ]; then
            opensearch_request "opening ${index}" "200" POST "${index}/_open" > /dev/null
            echo "Opened ${index}, which was closed." 1>&2
        fi
        # A clone an interrupted run left carries the mark it was cloned with, ready or not.
        wait_until_ready "$index" "$timeout"
        # And the block that run put on what it cloned from.
        [ -z "$(index_status "$ALIAS")" ] || allow_writes "$ALIAS"
        [ -z "$(index_status "$LEGACY")" ] || allow_writes "$LEGACY"
        return 0
    fi

    if [ -n "$(index_status "$ALIAS")" ]; then
        source="$ALIAS"
    elif alias_targets 2> /dev/null | grep -x "$LEGACY" > /dev/null; then
        source="$LEGACY"
    else
        opensearch_fail "no index holds the proteins of ${version}: ${index} is not there, and ${ALIAS} is not an index or an alias for ${LEGACY}. Load them with load.sh --uniprot-version ${version}."
    fi

    keep_as "$source" "$index" "$timeout"
    echo "Kept ${source} as ${index}, the index the API queries for ${version}." 1>&2
}

# Warns when OpenSearch's disk is past its low watermark, 85% unless the cluster says otherwise.
# Past it OpenSearch places no new shard on that node, and at the flood stage, 95%, it makes every
# index read-only, so a load running then fails part way. Each loaded version keeps its index until
# .deploy/prune.sh removes it, so this is how running out is heard about before a load breaks on it.
# Says nothing when OpenSearch cannot be asked: the load that follows reports that itself.
warn_opensearch_disk() {
    local watermark used

    watermark=$(curl -s -f --max-time 10 \
        "${OPENSEARCH_URL}/_cluster/settings?include_defaults=true&flat_settings=true&filter_path=*.cluster.routing.allocation.disk.watermark.low" 2>/dev/null \
        | sed -n 's/.*"cluster.routing.allocation.disk.watermark.low":"\([0-9]*\)%".*/\1/p') || true
    [ -n "$watermark" ] || watermark=85

    used=$(curl -s -f --max-time 10 "${OPENSEARCH_URL}/_cat/allocation?h=disk.percent" 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ && $1 > max { max = $1 } END { if (max != "") print max }') || true
    [ -n "$used" ] || return 0

    if [ "$used" -ge "$watermark" ]; then
        echo "WARN OpenSearch's disk is ${used}% full, past its ${watermark}% watermark. A load can fail part way once it reaches 95%; .deploy/prune.sh --keep N removes old versions." 1>&2
    fi
}
