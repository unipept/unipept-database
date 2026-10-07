# shellcheck shell=bash
#
# What this repository knows of the API on the same host: what it serves, and whether it follows a
# switch. All of it from the API's own `deploy.sh status`, never from its files. Uses die from
# core.sh, env_value and OUTPUT_DIR from config.sh, the links and database_version_of of
# versions.sh, and version_of_index from opensearch/lib.sh. Sourced through .deploy/lib.sh.

# The API's deploy.sh, where its install puts it. A host without it runs no API.
API_DEPLOY=${API_DEPLOY:-/opt/unipept-api/deploy/server/deploy.sh}

# The status_format of `deploy.sh status` these scripts read. The API raises it only where a line
# changes meaning or goes, so another one is refused rather than read wrongly.
readonly API_STATUS_FORMAT=1

# What the API's `deploy.sh status` says, its key=value lines. Fails, saying why, where it does not
# answer or answers in a format these scripts do not read, or where there is no deploy.sh, so no
# API, on this host: a caller that has an answer for that tests for API_DEPLOY itself.
api_status() {
    local status format

    [ -x "$API_DEPLOY" ] || { echo "Error: there is no API here: ${API_DEPLOY} is missing." 1>&2; return 1; }
    status=$("$API_DEPLOY" status) \
        || { echo "Error: ${API_DEPLOY} status did not answer (above)." 1>&2; return 1; }
    format=$(printf '%s\n' "$status" | env_value status_format)
    [ "$format" = "$API_STATUS_FORMAT" ] \
        || { echo "Error: ${API_DEPLOY} status answers in format '${format}', and these scripts read ${API_STATUS_FORMAT}. Install the unipept-database release that goes with this API." 1>&2; return 1; }
    printf '%s\n' "$status"
}

# Whether an INDEX_LOCATION names the suffix array through current, so the API follows a switch. By
# the directories they resolve to, the one holding current, so a trailing slash or a path through a
# link to OUTPUT_DIR says the same. Two paths that resolve to nothing are not the same one.
api_follows_current() {
    local location="${1%/}" named output
    [[ "$location" == */current/suffix-array ]] || return 1
    named=$(readlink -f "${location%/current/suffix-array}") || return 1
    output=$(readlink -f "$OUTPUT_DIR") || return 1
    [ "$named" = "$output" ]
}

# The versions this host serves, one per line: what current points at, and what the API serves by
# its status: the version of the directory INDEX_LOCATION names, where it names one itself, as on a
# host not yet pointed through current, and that of the index it queries, named by the .version of
# its files. Often the same one more than once. The one definition of served, which load.sh,
# build.sh, clone.sh and prune.sh all go by. Fails, after printing the first, where the API's
# deploy.sh is there and does not say.
served_versions() {
    local status named

    linked_version "$(current_link)" 2> /dev/null || true
    [ -x "$API_DEPLOY" ] || return 0
    status=$(api_status) || return 1
    # Only a version's own directory: uniprot-2025-12.bak names none.
    named=$(database_version_of "$(printf '%s\n' "$status" | env_value index_location)" 2> /dev/null) || true
    [[ ! "$named" =~ ^[0-9]{4}-[0-9]{2}$ ]] || echo "$named"
    version_of_index "$(printf '%s\n' "$status" | env_value opensearch_index)"
}

# Whether this host serves a version. Not grep -q: it would stop reading at the first match, and the
# write of a later line would then fail the pipeline under pipefail. Dies where the API does not say
# what it serves, adding what the second argument says: what it may serve is not replaced or loaded
# into on a guess.
is_served() {
    local versions
    versions=$(served_versions) \
        || die "the API's deploy.sh does not say which version this host serves (above), so ${1} is not changed. ${2:-}"
    printf '%s\n' "$versions" | grep -x "$1" > /dev/null
}

# Replacing the files of a version this host serves, under an API that has them open, is not a
# switch: it would serve other files from its next start, with nothing checked. Switch away first.
# The second argument says what a refusal leaves behind, whichever the reason.
refuse_replacing_served() {
    ! is_served "$1" "$2" \
        || die "${1} is the version this host serves, so its files are not replaced under the running API. ${2}Switch this host to another version with switch.sh first."
}
