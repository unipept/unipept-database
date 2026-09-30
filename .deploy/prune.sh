#!/usr/bin/env bash
#
# Removes old databases from this host: for each version, its directory under OUTPUT_DIR and its
# uniprot_entries-<version> index in OpenSearch, together. Run it with --help for the options.
#
# Nothing else removes them. switch.sh closes the indices of versions older than the two it
# switched between, which frees their memory, and keeps every version's data, so going back to one
# is a switch and not a rebuild. What that costs is disk, which is what this gives back.
#
# Kept, whatever --keep says:
#   - every version this host serves, by served_versions in lib.sh: what `current` points at, what
#     INDEX_LOCATION names where it names a version's directory itself, and what an alias of the old
#     name points at;
#   - the one `previous` points at, which switch.sh --back goes to;
#   - every version newer than the oldest of those, which is loaded ahead of a switch still to come;
#   - the --keep newest versions older than that, to go back to.
# What a host loaded before versioned indices kept, uniprot_entries-legacy and uniprot_entries itself,
# counts as the oldest, and is only removed once nothing may still need it: the API installed, and
# the one unipept-api's deploy.sh would roll back to, query the index of the version they serve,
# INDEX_LOCATION goes through current, and that index is open and loaded to the end. Until then it
# may be the only copy of what an API serves, and it says which of these is not so.
#
# Without a current link, with API settings it cannot read, or with OpenSearch not saying what the
# alias points at, there is no telling what the API serves, so nothing is removed. It holds the lock a
# load, a switch and migrate.sh take, so none of them works on what it removes.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

# The settings only this script has, before read_conf, so deploy.conf can set them.

# How many versions older than the one the API queries to keep. Required: removing is not undone.
KEEP=

# Whether to only say what would be removed.
DRY_RUN=false

read_conf

usage() {
    cat <<'USAGE'
Removes old databases from this host, each version's files and its OpenSearch index together.

  .deploy/prune.sh --keep N [OPTIONS]

  --keep N                 how many versions older than the one this host serves to keep, to go
                           back to. Required
  --dry-run                say what would be removed, and remove nothing
  --output-dir DIR         where the databases are
  --opensearch-url URL     the instance their indices are in
  --help                   print this message

Every version this host serves, the one before it, and every newer one, are always kept.
uniprot_entries and uniprot_entries-legacy, from before versioned indices, only go once the API
installed and the one deploy.sh would roll back to are 2.7.0 or newer, INDEX_LOCATION goes through
current, and the index of the version it serves is loaded to the end.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep) need_value "$1" "${2-}"; KEEP="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [ -n "$KEEP" ] || die "--keep is required: how many versions older than the one this host serves to keep."
    [[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep takes a number of versions, not '${KEEP}'."
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
require_opensearch

# Held until it ends, so no switch moves to a version, and no load fills one, while it removes them.
checkdep flock "util-linux"
take_opensearch_lock -x || die "$(lock_refused $?)"

SERVED=$(linked_version "$(current_link)" 2> /dev/null) \
    || die "there is no $(current_link) pointing at a version, so which one this host serves is not known. Nothing is removed."
[ ! -e "$API_ENV_FILE" ] || [ -r "$API_ENV_FILE" ] \
    || die "cannot read ${API_ENV_FILE}, so which files the API reads is not known. Nothing is removed."
BEFORE=$(linked_version "$(previous_link)" 2> /dev/null) || BEFORE=''

# Kept whatever --keep says: every version this host serves, by served_versions, and the one before,
# which switch.sh --back goes to. The oldest of the versioned ones is where what is kept is counted
# from; legacy has no place in that order, and is kept by name.
served=$(served_versions) \
    || die "OpenSearch does not say what the alias ${ALIAS} points at, so what an older API serves is not known. Nothing is removed."
SERVING=$(printf '%s\n' "$served" | awk 'NF && !seen[$0]++' | tr '\n' ' ')
PINNED=" ${SERVING}${BEFORE} "
ACTIVE="$SERVED"
for version in $SERVING $BEFORE; do
    if [[ "$version" =~ ^[0-9]{4}-[0-9]{2}$ ]] && [[ "$version" < "$ACTIVE" ]]; then
        ACTIVE="$version"
    fi
done

# What a host loaded before versioned indices kept, uniprot_entries itself and uniprot_entries-legacy,
# is only a candidate once nothing may still query it: the API installed, and the one deploy.sh keeps
# to roll back to, query the index of the version they serve, INDEX_LOCATION names the suffix array through current, and that index
# holds its proteins whole. Until then it may be the only copy of what the API serves.
OLD_INDICES_GO=false
if old_indices_unneeded && api_follows_current \
    && [ "$(index_status "${ALIAS}-${SERVED}")" = open ] && is_complete "${ALIAS}-${SERVED}"; then
    OLD_INDICES_GO=true
elif [ -n "$(index_status "$ALIAS")$(index_status "$LEGACY")" ]; then
    if ! old_indices_unneeded; then
        why="the API installed, or the one deploy.sh would roll back to ($(api_rollback_binary)), is older than ${API_VERSIONED_INDEX_SINCE}"
    elif ! api_follows_current; then
        why="INDEX_LOCATION does not go through $(current_link)"
    else
        why="${ALIAS}-${SERVED} is not open and loaded to the end"
    fi
    log "${ALIAS} and ${LEGACY}, from before versioned indices, are kept: ${why}."
fi

# Every version this host holds anything of, files or index, newest first. legacy and plain sort
# last, because they predate every versioned one, plain before legacy.
versions=$(
    {
        if [ "$OLD_INDICES_GO" = true ] && [ -n "$(index_status "$ALIAS")" ]; then
            echo plain
        fi
        # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
        for directory in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
            [ -d "$directory" ] && database_version_of "$directory"
        done
        curl -s -f "${OPENSEARCH_URL}/_cat/indices/${ALIAS}-*?h=index&expand_wildcards=all" | while read -r index; do
            version=$(version_of_index "$index")
            [ "$version" != legacy ] || [ "$OLD_INDICES_GO" = true ] || continue
            printf '%s\n' "$version"
        done || true
    } | sed 's/^legacy$/0000-01 legacy/; s/^plain$/0000-00 plain/; s/^\([0-9-]*\)$/\1 \1/' | sort -u -r -k1,1 | awk 'NF == 2 { print $2 }'
)

# Newer than the older of what is served is kept: the other of the two, or loaded ahead of a switch.
# That one is kept, and of those older, the first KEEP.
keep=' '
remove=''
seen_active=false
kept_older=0
for version in $versions; do
    if [ "$version" = "$ACTIVE" ]; then
        keep+="${version} "
        seen_active=true
    elif [[ "$PINNED" == *" ${version} "* ]]; then
        keep+="${version} "
    elif [ "$seen_active" = false ]; then
        keep+="${version} "
    elif [ "$kept_older" -lt "$KEEP" ]; then
        keep+="${version} "
        kept_older=$((kept_older + 1))
    else
        remove+="${version} "
    fi
done

log "This host serves ${SERVING% }${BEFORE:+, and switched from ${BEFORE}}. Keeping:${keep% }"
if [ -z "$remove" ]; then
    log "Nothing to remove."
    exit 0
fi
log "Removing: ${remove% }"
[ "$DRY_RUN" != true ] || { log "A dry run, so nothing is removed."; exit 0; }

for version in $remove; do
    if [ "$version" = legacy ]; then
        index="$LEGACY"
        directory=''
    elif [ "$version" = plain ]; then
        index="$ALIAS"
        directory=''
    else
        index="${ALIAS}-${version}"
        directory="${OUTPUT_DIR}/uniprot-${version}"
    fi

    # Before the files, so a delete OpenSearch refuses leaves the version whole to try again.
    if [ -n "$(index_status "$index")" ]; then
        opensearch_request "deleting the ${index} index" "200" DELETE "$index" > /dev/null
        log "Deleted the ${index} index."
    fi

    if [ -n "$directory" ] && [ -e "$directory" ]; then
        rm -rf "${directory:?}"
        log "Removed ${directory}."
    fi
done
