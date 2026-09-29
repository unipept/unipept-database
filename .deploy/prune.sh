#!/usr/bin/env bash
#
# Removes old databases from this host: for each version, its directory under OUTPUT_DIR and its
# uniprot_entries-<version> index in OpenSearch, together. Run it with --help for the options.
#
# Nothing else removes them. Activating a version closes the index of the one before, which frees
# its memory, and keeps every version's data, so going back to one is a switch and not a rebuild.
# What that costs is disk, which is what this gives back.
#
# What the API serves is two things, which can be on different versions for a while: the proteins,
# through the uniprot_entries alias, and the files, through INDEX_LOCATION in the API's environment
# file on a host that runs the API. load.sh --activate moves only the first. Kept, whatever --keep
# says:
#   - the version of each, and every version newer than the older of the two, which is loaded ahead
#     of a switch still to come;
#   - the --keep newest versions older than that, to go back to.
# The old index a host had before versioned indices, uniprot_entries-legacy, counts as the oldest.
#
# Without an alias, or with an environment file that cannot be read or names no version, there is
# no telling what the API serves, so nothing is removed.

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

# Where the API on this host keeps INDEX_LOCATION, which unipept-api's install puts there. A host
# without it runs no API, and only the alias says what is served.
API_ENV_FILE=${API_ENV_FILE:-/opt/unipept-api/etc/unipept-api.env}

read_conf

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

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
require_opensearch

active_index=$(alias_target)
QUERIED=$(version_of_index "$active_index")
[ -n "$QUERIED" ] \
    || die "${ALIAS} is not an alias for a version's index, so which version the API queries is not known. Nothing is removed."

SERVED=''
if [ -e "$API_ENV_FILE" ]; then
    [ -r "$API_ENV_FILE" ] || die "cannot read ${API_ENV_FILE}, so which files the API reads is not known. Nothing is removed."
    location=$(sed -n 's/^INDEX_LOCATION=//p' "$API_ENV_FILE" | tail -n 1)
    SERVED=$(database_version_of "$location") \
        || die "INDEX_LOCATION in ${API_ENV_FILE} is '${location}', which names no version, so which files the API reads is not known. Nothing is removed."
fi

# The older of the two: what is kept is counted from there. legacy is older than any version.
ACTIVE="$QUERIED"
if [ -n "$SERVED" ] && [[ "${SERVED/legacy/0000-00}" < "${QUERIED/legacy/0000-00}" ]]; then
    ACTIVE="$SERVED"
fi

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
    elif [ "$seen_active" = false ]; then
        keep+="${version} "
    elif [ "$kept_older" -lt "$KEEP" ]; then
        keep+="${version} "
        kept_older=$((kept_older + 1))
    else
        remove+="${version} "
    fi
done

log "The API queries ${active_index}${SERVED:+ and reads the files of ${SERVED}}. Keeping:${keep% }"
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
