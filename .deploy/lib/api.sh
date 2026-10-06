# shellcheck shell=bash
#
# What this repository knows of the API on the same host: which version it serves, which release of
# it is installed, and whether it follows a switch. The one place that looks at the API's files.
# Uses die from core.sh, OUTPUT_DIR from config.sh, the links of versions.sh, and alias_targets,
# version_of_index, opensearch_answers and ALIAS from opensearch/lib.sh. Sourced through
# .deploy/lib.sh.

# The API on this host, where its own install puts it: its settings, of which INDEX_LOCATION is read
# here, and the script that stops and starts it. A host without them runs no API.
API_ENV_FILE=${API_ENV_FILE:-/opt/unipept-api/etc/unipept-api.env}
# shellcheck disable=SC2034 # read by the scripts that source this file
API_DEPLOY=${API_DEPLOY:-/opt/unipept-api/lib/deploy.sh}
API_BINARY=${API_BINARY:-/opt/unipept-api/bin/unipept-api}

# The first unipept-api release that queries uniprot_entries-<version>, the index of the version its
# files are from. An older one queries uniprot_entries itself, or the alias of that name, and needs
# what a host loaded before versioned indices kept.
readonly API_VERSIONED_INDEX_SINCE=2.7.0

# INDEX_LOCATION in the API's settings on this host, or nothing where there are none.
api_index_location() {
    [ -r "$API_ENV_FILE" ] || return 0
    sed -n 's/^INDEX_LOCATION=//p' "$API_ENV_FILE" | tail -n 1
}

# Whether INDEX_LOCATION names the suffix array through current, so the API follows a switch. By
# the directories they resolve to, the one holding current, so a trailing slash or a path through a
# link to OUTPUT_DIR says the same. Two paths that resolve to nothing are not the same one.
api_follows_current() {
    local location named output
    location=$(api_index_location)
    location="${location%/}"
    [[ "$location" == */current/suffix-array ]] || return 1
    named=$(readlink -f "${location%/current/suffix-array}") || return 1
    output=$(readlink -f "$OUTPUT_DIR") || return 1
    [ "$named" = "$output" ]
}

# The versions this host serves, one per line, in this order: what current points at, what
# INDEX_LOCATION names where it names a version's directory itself, as on a host not yet pointed
# through current, and what every alias of the old name an earlier release left points at, which an
# API from before versioned indices queries, legacy included. The one definition of served, which
# load.sh, build.sh, clone.sh and prune.sh all go by. Often the same one more than once. Fails, after
# printing the rest, where OpenSearch does not say what the alias points at.
served_versions() {
    local targets index

    linked_version "$(current_link)" 2> /dev/null || true
    database_version_of "$(api_index_location)" 2> /dev/null || true
    targets=$(alias_targets 2> /dev/null) || return 1
    for index in $targets; do
        version_of_index "$index"
    done
}

# Whether this host serves a version, by any of them. Not grep -q: it would stop reading at the first
# match, and the write of a later line would then fail the pipeline under pipefail. With strict, what
# the alias points at has to be known where OpenSearch answers: a load cannot take it for nothing.
# Without, as for a build on a host whose OpenSearch is stopped for it, the links suffice.
is_served() {
    local versions
    if ! versions=$(served_versions); then
        # An OpenSearch that does not answer at all drops nothing either: the load fails on its own.
        [ "${2:-}" != strict ] || ! opensearch_answers \
            || die "OpenSearch does not say what the alias ${ALIAS} points at, so what this host serves is not known."
    fi
    printf '%s\n' "$versions" | grep -x "$1" > /dev/null
}

# Replacing the files of a version this host serves, under an API that has them open, is not a
# switch: it would serve other files from its next start, with nothing checked. Switch away first.
refuse_replacing_served() {
    ! is_served "$1" \
        || die "${1} is the version this host serves, so its files are not replaced under the running API. ${2}Switch this host to another version with switch.sh first."
}

# The X.Y.Z of an API binary, from its own --version, a pre-release or build suffix left off: 2.7.0 for
# 2.7.0-rc.1, which already is that release's code. Fails where it cannot be run or says nothing so.
api_binary_version() {
    local reported
    [ -x "$1" ] || return 1
    reported=$("$1" --version 2> /dev/null | awk '{ print $NF }') || return 1
    reported="${reported%%[-+]*}"
    [[ "$reported" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$reported"
}

# Whether a version is API_VERSIONED_INDEX_SINCE or newer.
queries_versioned_index() {
    [ "$(printf '%s\n%s\n' "$API_VERSIONED_INDEX_SINCE" "$1" | sort -V | head -n 1)" = "$API_VERSIONED_INDEX_SINCE" ]
}

# Whether an API binary queries the index of the version it serves: 0 it does, 1 it is older than
# API_VERSIONED_INDEX_SINCE, 2 it cannot be run to say. The one test switch.sh and prune.sh make.
api_state() {
    local version
    version=$(api_binary_version "$1") || return 2
    queries_versioned_index "$version" || return 1
}

# The binary the API keeps beside the installed one, for its rollback.
api_rollback_binary() { echo "${API_BINARY}.previous"; }

# Whether nothing installed still needs what a host loaded before versioned indices kept: the API
# installed queries the index of its version, and so does the one deploy.sh would roll back to, where
# there is one. A rollback to an older one would serve nothing without uniprot_entries or its alias.
old_indices_unneeded() {
    api_state "$API_BINARY" || return 1
    [ ! -e "$(api_rollback_binary)" ] || api_state "$(api_rollback_binary)"
}
