#!/usr/bin/env bash
#
# Loads the proteins of a finished database into this host's OpenSearch. build.sh and clone.sh put
# a database in place; this is the step that changes what the API's protein search answers. Run it
# with --help for the options.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

# The OpenSearch instance the proteins are loaded into.
OPENSEARCH_URL=http://localhost:9200

read_conf

# The settings only this script has. lib.sh holds the ones it shares. After read_conf rather than
# before, as in verify.sh: a UNIPROT_VERSION in deploy.conf is the release clone.sh fetches, and
# which database to load is said here or is the newest.

# Which database to load. Empty means the newest one under OUTPUT_DIR.
UNIPROT_VERSION=

# Rows to pass over, to continue a load that stopped part way. Handed to opensearch/load.sh, which
# then keeps the index as it is rather than recreating it.
SKIP_ROWS=

usage() {
    cat <<'USAGE'
Loads the proteins of a finished database into this host's OpenSearch.

  .deploy/load.sh [OPTIONS]

  --uniprot-version YYYY-MM  load this one under OUTPUT_DIR, default the newest there
  --output-dir DIR         where the databases are
  --opensearch-url URL     the instance the proteins are loaded into
  --skip ROWS              continue a load that stopped part way, passing over this many rows
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

# Before the load, which drops and recreates the index the API queries: proteins loaded from a
# database the API cannot serve would pair with files that are not there.
verify_database "${DATABASE_DIR}/suffix-array" \
    || die "${DATABASE_DIR} is missing files the API needs, or is not the version it is named after."
[ -s "$ENTRIES" ] || die "${DATABASE_DIR} has no tables/uniprot_entries.tsv.lz4 to load."

log "Started loading UniProtKB ${UNIPROT_VERSION} into OpenSearch at ${OPENSEARCH_URL}."
"${HERE}/../opensearch/load.sh" \
    --opensearch-url "$OPENSEARCH_URL" \
    --uniprot-entries "$ENTRIES" \
    ${SKIP_ROWS:+--skip "$SKIP_ROWS"}
log "Finished loading UniProtKB ${UNIPROT_VERSION} into OpenSearch."
