#!/usr/bin/env bash
#
# Loads the proteins of a finished database into this host's OpenSearch, as an index of their own,
# uniprot_entries-<version>. The API queries the index of the version it serves, which switch.sh
# changes, so a load of another version changes nothing it answers. Run it with --help for the
# options.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

read_conf

# The settings only this script has. lib.sh holds the ones it shares. After read_conf rather than
# before, as in verify.sh: a UNIPROT_VERSION in deploy.conf is the release clone.sh fetches, and
# which database to load is said here or is the newest.

# Which database to load. Empty means the newest one under OUTPUT_DIR.
UNIPROT_VERSION=

# Rows to pass over, to continue a load that stopped part way. Handed to opensearch/load.sh, which
# then keeps the index as it is rather than recreating it.
SKIP_ROWS=

# Whether the version this host serves may be reloaded. Off, that is refused: from the moment the
# loader drops its index until the load finishes, the API searches a partial one.
REPLACE_LIVE=false

# Whether to only say if the version is loaded to the end, and load nothing. What distribute.sh and
# switch.sh ask a host before they rely on its index.
CHECK=false

usage() {
    cat <<'USAGE'
Loads the proteins of a finished database into this host's OpenSearch.

  .deploy/load.sh [OPTIONS]

  --uniprot-version YYYY-MM  load this one under OUTPUT_DIR, default the newest there
  --output-dir DIR         where the databases are
  --opensearch-url URL     the instance the proteins are loaded into
  --skip ROWS              continue a load that stopped part way, passing over this many rows
  --replace-live           allow reloading the version this host serves, which empties the API's
                           protein search until the load finishes
  --check                  load nothing: exit 0 if the version is loaded to the end, 1 if not
  --help                   print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib.sh and in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uniprot-version) need_value "$1" "${2-}"; valid_version "$2"; UNIPROT_VERSION="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --skip) need_value "$1" "${2-}"; SKIP_ROWS="$2"; shift 2 ;;
            --replace-live) REPLACE_LIVE=true; shift ;;
            --check) CHECK=true; shift ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [ -z "$SKIP_ROWS" ] || [[ "$SKIP_ROWS" =~ ^[0-9]+$ ]] || die "--skip takes a number of rows, not '${SKIP_ROWS}'."
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."

[ -n "$UNIPROT_VERSION" ] || UNIPROT_VERSION=$(latest_version)
DATABASE_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
ENTRIES="${DATABASE_DIR}/tables/uniprot_entries.tsv.lz4"
INDEX_NAME="uniprot_entries-${UNIPROT_VERSION}"

if [ "$CHECK" = true ]; then
    if "${HERE}/../opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name "$INDEX_NAME" --check-complete; then
        echo "${INDEX_NAME} is loaded to the end."
        exit 0
    fi
    echo "${INDEX_NAME} is not loaded, or its load did not finish." 1>&2
    exit 1
fi

# Before the load, and so before anything can switch to it: proteins loaded from a database the API
# cannot serve would pair with files that are not there.
verify_database "${DATABASE_DIR}/suffix-array" \
    || die "${DATABASE_DIR} is missing files the API needs, or is not the version it is named after."
[ -s "$ENTRIES" ] || die "${DATABASE_DIR} has no tables/uniprot_entries.tsv.lz4 to load."

# The version the API serves is queried while it runs: dropping its index would empty the protein
# search until the load finishes. Where a host has no current link yet, INDEX_LOCATION says which one
# it serves. A load continued with --skip keeps its index, and drops nothing.
if is_served "$UNIPROT_VERSION" && [ -z "$SKIP_ROWS" ] && [ "$REPLACE_LIVE" != true ]; then
    die "${UNIPROT_VERSION} is the version this host serves. Reloading it empties the API's protein search until the load finishes; pass --replace-live to do so anyway."
fi

# Held until the load ends, so switch.sh does not stop OpenSearch under it.
checkdep flock "util-linux"
take_opensearch_lock -s || case $? in
    1) die "switch.sh is switching this host, and stops OpenSearch to do so. Load once it has finished." ;;
    *) die "without the lock, a switch could stop OpenSearch under this load. Make ${OPENSEARCH_LOCK} writable for $(id -un), or set OPENSEARCH_LOCK." ;;
esac

warn_opensearch_disk "$OPENSEARCH_URL"

log "Started loading UniProtKB ${UNIPROT_VERSION} into ${INDEX_NAME} at ${OPENSEARCH_URL}."
loader_arguments=(--opensearch-url "$OPENSEARCH_URL" --uniprot-entries "$ENTRIES" --index-name "$INDEX_NAME")
[ -z "$SKIP_ROWS" ] || loader_arguments+=(--skip "$SKIP_ROWS")
"${HERE}/../opensearch/load.sh" "${loader_arguments[@]}"
log "Finished loading UniProtKB ${UNIPROT_VERSION} into ${INDEX_NAME}."
log "The API does not query it until this host switches to it: switch.sh --uniprot-version ${UNIPROT_VERSION}."
