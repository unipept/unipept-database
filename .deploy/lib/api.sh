# shellcheck shell=bash
#
# What this repository knows of the API on the same host: what it serves, and whether it follows a
# switch. All of it from the API's own `deploy.sh status`, never from its files. Uses die from
# core.sh, env_value and OUTPUT_DIR from config.sh, the links of versions.sh, and version_of_index
# from opensearch/lib.sh. Sourced through .deploy/lib.sh.

# The API's deploy.sh, where its install puts it. A host without it runs no API.
API_DEPLOY=${API_DEPLOY:-/opt/unipept-api/lib/deploy.sh}

# The status_format of `deploy.sh status` these scripts read. The API raises it only where a line
# changes meaning or goes, so another one is refused rather than read wrongly.
readonly API_STATUS_FORMAT=1

# One value of what the API's `deploy.sh status` says. Fails with 3 where there is no deploy.sh, so
# no API, on this host, and with 2, saying why, where it does not answer or answers in a format these
# scripts do not read.
api_value() {
    local status format

    [ -x "$API_DEPLOY" ] || return 3
    status=$("$API_DEPLOY" status) \
        || { echo "Error: ${API_DEPLOY} status did not answer (above)." 1>&2; return 2; }
    format=$(printf '%s\n' "$status" | env_value status_format)
    [ "$format" = "$API_STATUS_FORMAT" ] \
        || { echo "Error: ${API_DEPLOY} status answers in format '${format}', and these scripts read ${API_STATUS_FORMAT}. Install the unipept-database release that goes with this API." 1>&2; return 2; }
    printf '%s\n' "$status" | env_value "$1"
}

# INDEX_LOCATION in the API's settings on this host, or nothing where it runs no API.
api_index_location() {
    api_value index_location || [ $? -eq 3 ]
}

# Whether INDEX_LOCATION names the suffix array through current, so the API follows a switch. By
# the directories they resolve to, the one holding current, so a trailing slash or a path through a
# link to OUTPUT_DIR says the same. Two paths that resolve to nothing are not the same one.
api_follows_current() {
    local location named output
    location=$(api_index_location) || return 1
    location="${location%/}"
    [[ "$location" == */current/suffix-array ]] || return 1
    named=$(readlink -f "${location%/current/suffix-array}") || return 1
    output=$(readlink -f "$OUTPUT_DIR") || return 1
    [ "$named" = "$output" ]
}

# The versions this host serves, one per line: what current points at, and the version of the index
# the API queries, by its status, which differs only where INDEX_LOCATION names a version's
# directory itself, as on a host not yet pointed through current. Often the same one twice. The one
# definition of served, which load.sh, build.sh, clone.sh and prune.sh all go by. Fails, after
# printing the first, where the API's deploy.sh is there and does not say.
served_versions() {
    local index

    linked_version "$(current_link)" 2> /dev/null || true
    index=$(api_value opensearch_index) || [ $? -eq 3 ] || return 1
    [ -z "$index" ] || version_of_index "$index"
}

# Whether this host serves a version. Not grep -q: it would stop reading at the first match, and the
# write of a later line would then fail the pipeline under pipefail. Dies where the API does not say
# what it serves: what it may serve is not replaced or loaded into on a guess.
is_served() {
    local versions
    versions=$(served_versions) \
        || die "the API's deploy.sh does not say which version this host serves (above), so none is replaced or loaded into."
    printf '%s\n' "$versions" | grep -x "$1" > /dev/null
}

# Replacing the files of a version this host serves, under an API that has them open, is not a
# switch: it would serve other files from its next start, with nothing checked. Switch away first.
refuse_replacing_served() {
    ! is_served "$1" \
        || die "${1} is the version this host serves, so its files are not replaced under the running API. ${2}Switch this host to another version with switch.sh first."
}
