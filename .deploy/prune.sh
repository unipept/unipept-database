#!/usr/bin/env bash
#
# Removes old databases from this host: for each version, its directory under OUTPUT_DIR and its
# uniprot_entries-<version> index in OpenSearch, together. Run it with --help for the options.
#
# Nothing else removes them. Activating a version closes the index of the one before, which frees
# its memory, and keeps every version's data, so going back to one is a switch and not a rebuild.
# What that costs is disk, which is what this gives back.
#
# Kept, whatever --keep says:
#   - the version the API queries, which is the one the uniprot_entries alias points at;
#   - every version newer than that one, which is loaded ahead of a switch still to come;
#   - the --keep newest versions older than it, to go back to.
# The old index a host had before versioned indices, uniprot_entries-legacy, counts as the oldest.
#
# Without an alias there is no telling which version the API queries, so nothing is removed.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"
# shellcheck source=../opensearch/lib.sh
source "${HERE}/../opensearch/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

# The OpenSearch instance the indices are in.
OPENSEARCH_URL=http://localhost:9200

read_conf

# The settings only this script has.

# How many versions older than the one the API queries to keep. Required: removing is not undone.
KEEP=

# Whether to only say what would be removed.
DRY_RUN=false

usage() {
    cat <<'USAGE'
Removes old databases from this host, each version's files and its OpenSearch index together.

  .deploy/prune.sh --keep N [OPTIONS]

  --keep N                 how many versions older than the one the API queries to keep, to go
                           back to. Required
  --dry-run                say what would be removed, and remove nothing
  --output-dir DIR         where the databases are
  --opensearch-url URL     the instance their indices are in
  --help                   print this message

The version the API queries, and every newer one, are always kept.
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

    [ -n "$KEEP" ] || die "--keep is required: how many versions older than the one the API queries to keep."
    [[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep takes a number of versions, not '${KEEP}'."
}

# The version an index holds, YYYY-MM or legacy, or nothing for one that is not a database's.
version_of_index() {
    local version="${1#"${ALIAS}"-}"

    if [ "$1" = "$LEGACY" ]; then
        echo legacy
    elif [[ "$version" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "$version"
    fi
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
require_opensearch

active_index=$(alias_target)
ACTIVE=$(version_of_index "$active_index")
[ -n "$ACTIVE" ] \
    || die "${ALIAS} is not an alias for a version's index, so which version the API queries is not known. Nothing is removed."

# Every version this host holds anything of, files or index, newest first. legacy sorts last,
# because it predates every versioned one.
versions=$(
    {
        # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
        for directory in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
            [ -d "$directory" ] && database_version_of "$directory"
        done
        curl -s -f "${OPENSEARCH_URL}/_cat/indices/${ALIAS}-*?h=index&expand_wildcards=all" | while read -r index; do
            version_of_index "$index"
        done || true
    } | sed 's/^legacy$/0000-00 legacy/; s/^\([0-9-]*\)$/\1 \1/' | sort -u -r -k1,1 | awk '{ print $2 }'
)

# Newer than the active one is kept, being loaded ahead of a switch; the active one is kept; and
# of those older, the first KEEP.
keep=' '
remove=''
seen_active=false
kept_older=0
for version in $versions; do
    if [ "$version" = "$ACTIVE" ]; then
        keep+="${version} "
        seen_active=true
    elif [ "$seen_active" = false ]; then
        keep+="${version} "
    elif [ "$kept_older" -lt "$KEEP" ]; then
        keep+="${version} "
        kept_older=$((kept_older + 1))
    else
        remove+="${version} "
    fi
done

log "The API queries ${active_index}. Keeping:${keep% }"
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
