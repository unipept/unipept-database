#!/usr/bin/env bash
#
# Sets up a host that runs the API for switch.sh, once. Run it with --help for the options.
#
# switch.sh switches by moving the `current` link in OUTPUT_DIR, which the API's INDEX_LOCATION
# names the suffix array through, and the API queries the index named after the version it serves.
# A host set up before either has neither: INDEX_LOCATION names a version's directory itself, and
# the proteins may be in uniprot_entries, or in uniprot_entries-legacy behind an alias of that name.
#
# Nothing here changes what the API serves: the link names the files it reads already, and the index
# holds the proteins it queries already, under one name more. Run it again at any time; a host that
# is set up is left as it is.
#
# Flow:
#   1. Read the version the API serves from its INDEX_LOCATION.
#   2. Point `current` at that version's directory, unless there is a current link already, which
#      is then switch.sh's to move.
#   3. Keep the proteins of the version `current` points at in the index named after it: a clone of
#      uniprot_entries, or of uniprot_entries-legacy, where they are still there. A clone shares
#      the files of the index it is made from, so it costs no copy.
#   4. Say what is left: INDEX_LOCATION naming the suffix array through `current`, which is a line
#      in the API's settings, and nothing here edits them.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sets the shell options and the traps every script here runs with: see lib/core.sh.
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

read_conf

# Seconds a clone has to be ready to serve.
readonly READY_TIMEOUT=600

usage() {
    cat <<'USAGE'
Sets up a host that runs the API for switch.sh, once. Changes nothing the API serves.

  .deploy/migrate.sh [OPTIONS]

  --output-dir DIR         where the databases are
  --opensearch-url URL     the instance their indices are in
  --help                   print this message

Run it as the user the API runs as.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done
}

parse_arguments "$@"
refuse_root

# It clones and opens indices, so no switch stops OpenSearch under it and no prune removes what it
# clones from.
require flock:util-linux
take_opensearch_lock -x || die "$(lock_refused $?)"

[ -f "$API_ENV_FILE" ] || die "there is no ${API_ENV_FILE}, so this host runs no API and has nothing to switch."
[ -r "$API_ENV_FILE" ] || die "cannot read ${API_ENV_FILE}. Run this as the user the API runs as."

CURRENT=$(current_link)
LOCATION=$(api_index_location)

if [ -L "$CURRENT" ]; then
    # The proteins cloned below are the ones INDEX_LOCATION serves, so they have to be that version's.
    LINKED=$(linked_version "$CURRENT") || die "${CURRENT} points at $(readlink "$CURRENT"), which is no version's directory."
    NAMED=$(database_version_of "$LOCATION" 2> /dev/null) || NAMED=''
    [ -z "$NAMED" ] || [ "$NAMED" = "$LINKED" ] \
        || die "${CURRENT} points at ${LINKED}, and INDEX_LOCATION names ${NAMED}: the proteins the API serves are ${NAMED}'s, and would be kept as ${LINKED}'s. Point ${CURRENT} at uniprot-${NAMED}, or INDEX_LOCATION through it, first."
    log "${CURRENT} points at $(readlink "$CURRENT") already, and is left as it is."
else
    VERSION=$(database_version_of "$LOCATION") \
        || die "INDEX_LOCATION in ${API_ENV_FILE} is '${LOCATION}', which names no version, so which one this host serves is not known. Point ${CURRENT} at it yourself: ln -s uniprot-YYYY-MM ${CURRENT}"
    DIRECTORY="${LOCATION%/}"
    DIRECTORY="${DIRECTORY%/suffix-array}"
    TARGET="$DIRECTORY"
    [ "$DIRECTORY" != "${OUTPUT_DIR%/}/uniprot-${VERSION}" ] || TARGET="uniprot-${VERSION}"
    [ -d "$DIRECTORY" ] || die "INDEX_LOCATION names ${DIRECTORY}, which is not there."
    point_link "$CURRENT" "$TARGET"
    log "Pointed ${CURRENT} at ${TARGET}, the version the API serves."
fi

VERSION=$(linked_version "$CURRENT") || die "${CURRENT} points at $(readlink "$CURRENT"), which is no version's directory."

require_opensearch
ensure_versioned_index "$VERSION" "$READY_TIMEOUT"
log "The proteins of ${VERSION} are in ${ALIAS}-${VERSION}, which the API queries."

if api_follows_current; then
    log "INDEX_LOCATION names ${CURRENT}/suffix-array. This host is set up for switch.sh."
else
    cat >&2 <<EOF

Still to do, so the API follows switch.sh: set this in ${API_ENV_FILE},

  INDEX_LOCATION=${CURRENT}/suffix-array

It names the same files, so nothing changes until the API next starts.
EOF
fi
