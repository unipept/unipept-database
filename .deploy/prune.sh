#!/usr/bin/env bash
#
# Removes old databases from this host: for each version, its directory under OUTPUT_DIR and its
# uniprot_entries-<version> index in OpenSearch, together. Run it with --help for the options.
#
# Nothing else removes them. switch.sh closes the indices of versions older than the two it
# switched between, which frees their memory, and keeps every version's data, so going back to one
# is a switch and not a rebuild. What that costs is disk, which is what this gives back.
#
# What the API serves is the version the `current` link points at, and switch.sh --back goes to the
# one `previous` points at. Kept, whatever --keep says:
#   - both, and every version newer than the older of the two, which is loaded ahead of a switch
#     still to come;
#   - the --keep newest versions older than that, to go back to.
# What a host loaded before versioned indices kept, uniprot_entries-legacy and uniprot_entries itself,
# counts as the oldest. The version INDEX_LOCATION names is kept too, where it names one rather than
# the suffix array through current.
#
# Without a current link there is no telling what the API serves, so nothing is removed.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"
# shellcheck source=../opensearch/lib.sh
source "${HERE}/../opensearch/lib.sh"

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

The version this host serves, the one before it, and every newer one, are always kept.
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
take_opensearch_lock -x || case $? in
    1) die "a load or a switch is running on this host. Prune once it has finished." ;;
    *) die "without the lock, a load or a switch could run while this removes versions. Make ${OPENSEARCH_LOCK} writable for $(id -un), or set OPENSEARCH_LOCK." ;;
esac

SERVED=$(linked_version "$(current_link)" 2> /dev/null) \
    || die "there is no $(current_link) pointing at a version, so which one this host serves is not known. Nothing is removed."
BEFORE=$(linked_version "$(previous_link)" 2> /dev/null) || BEFORE=''
# What INDEX_LOCATION names, where it names a version rather than current: the files the API reads
# until it is pointed through the link, which removing would take from under it.
IN_USE=$(database_version_of "$(api_index_location)" 2> /dev/null) || IN_USE=''
# What an alias of the old name points at, where an earlier release left one: an API from before
# versioned indices queries through it, whatever INDEX_LOCATION says.
ALIASED=$(version_of_index "$(alias_target)")

# Kept whatever --keep says. The oldest of the versioned ones is where what is kept is counted from;
# legacy has no place in that order, and is kept by name.
PINNED=" ${SERVED} ${BEFORE} ${IN_USE} ${ALIASED} "
ACTIVE="$SERVED"
for version in "$BEFORE" "$IN_USE" "$ALIASED"; do
    if [[ "$version" =~ ^[0-9]{4}-[0-9]{2}$ ]] && [[ "$version" < "$ACTIVE" ]]; then
        ACTIVE="$version"
    fi
done

# Every version this host holds anything of, files or index, newest first. legacy and plain sort
# last, because they predate every versioned one, plain before legacy. plain, the index
# uniprot_entries itself, is only a candidate once INDEX_LOCATION names the suffix array through
# current: until then an API from before versioned indices may still query it.
versions=$(
    {
        if [ "$(api_index_location)" = "$(current_link)/suffix-array" ] && [ -n "$(index_status "$ALIAS")" ]; then
            echo plain
        fi
        # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
        for directory in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
            [ -d "$directory" ] && database_version_of "$directory"
        done
        curl -s -f "${OPENSEARCH_URL}/_cat/indices/${ALIAS}-*?h=index&expand_wildcards=all" | while read -r index; do
            version_of_index "$index"
        done || true
    } | sed 's/^legacy$/0000-01 legacy/; s/^plain$/0000-00 plain/; s/^\([0-9-]*\)$/\1 \1/' | sort -u -r -k1,1 | awk '{ print $2 }'
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

log "This host serves ${SERVED}${BEFORE:+, and switched from ${BEFORE}}${IN_USE:+; INDEX_LOCATION names ${IN_USE}}${ALIASED:+; the old alias points at ${ALIASED}}. Keeping:${keep% }"
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
