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
#   - every version this host serves, by served_versions in lib/api.sh: what `current` points at,
#     and what the API serves by its deploy.sh status: the version of the index it queries, or of
#     the directory INDEX_LOCATION names;
#   - the one `previous` points at, which switch.sh --back goes to;
#   - every version newer than the oldest of those, which is loaded ahead of a switch still to come;
#   - the --keep newest versions older than that, to go back to.
#
# Without a current link, or where the API's deploy.sh does not say which version it serves, there
# is no telling what the API serves, so nothing is removed. It holds the lock a load and a switch
# take, so neither works on what it removes.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Beside this script once install.sh has placed both in /opt/unipept-database/bin, one level up in
# a repository checkout.
# shellcheck source=../lib.sh
if [ -f "${HERE}/lib.sh" ]; then
    source "${HERE}/lib.sh"
else
    source "${HERE}/../lib.sh"
fi

# The settings only this script has, before read_conf, so deploy.conf can set them.

# How many versions older than the one this host serves to keep. Required: removing is not undone.
KEEP=

# Whether to only say what would be removed.
DRY_RUN=false

read_conf

usage() {
    cat <<'USAGE'
Removes old databases from this host, each version's files and its OpenSearch index together.

  .deploy/server/prune.sh --keep N [OPTIONS]

  --keep N                   how many versions older than the one this host serves to keep, to go
                             back to. Required
  --dry-run                  say what would be removed, and remove nothing
  --output-dir DIR           where the databases are
  --opensearch-url URL       the instance their indices are in
  --help                     print this message

Every version this host serves, the one before it, and every newer one, are always kept.

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib/ and in this script.
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
            *) unknown_option "$1" ;;
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
require flock:util-linux
take_opensearch_lock -x || die "$(lock_refused $?)"

SERVED=$(linked_version "$(current_link)" 2> /dev/null) \
    || die "there is no $(current_link) pointing at a version, so which one this host serves is not known. Nothing is removed."
BEFORE=$(linked_version "$(previous_link)" 2> /dev/null) || BEFORE=''

# Kept whatever --keep says: every version this host serves, by served_versions, and the one before,
# which switch.sh --back goes to. The oldest of them is where what is kept is counted from.
served=$(served_versions) \
    || die "the API's deploy.sh does not say which version this host serves (above). Nothing is removed."
SERVING=$(printf '%s\n' "$served" | awk 'NF && !seen[$0]++' | tr '\n' ' ')
PINNED=" ${SERVING}${BEFORE} "
ACTIVE="$SERVED"
for version in $SERVING $BEFORE; do
    if [[ "$version" < "$ACTIVE" ]]; then
        ACTIVE="$version"
    fi
done

# Every version this host holds anything of, files or index, newest first.
versions=$(
    {
        # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
        for directory in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
            [ -d "$directory" ] && database_version_of "$directory"
        done
        curl -s -f "${OPENSEARCH_URL}/_cat/indices/${INDEX_PREFIX}-*?h=index&expand_wildcards=all" | while read -r index; do
            version_of_index "$index"
        done || true
    } | sort -u -r
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
    index="${INDEX_PREFIX}-${version}"
    directory="${OUTPUT_DIR}/uniprot-${version}"

    # Before the files, so a delete OpenSearch refuses leaves the version whole to try again.
    if [ -n "$(index_status "$index")" ]; then
        opensearch_request "deleting the ${index} index" "200" DELETE "$index" > /dev/null
        log "Deleted the ${index} index."
    fi

    if [ -e "$directory" ]; then
        rm -rf "${directory:?}"
        log "Removed ${directory}."
    fi
done
