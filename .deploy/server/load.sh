#!/usr/bin/env bash
#
# Loads the proteins of a finished database into this host's OpenSearch, as an index of their own,
# uniprot_entries-<version>. The API queries the index of the version it serves, which switch.sh
# changes, so a load of another version changes nothing it answers. Run it with --help for the
# options.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Beside this script once install.sh has placed both in /opt/unipept-database/bin, one level up in
# a repository checkout.
# shellcheck source=../lib.sh
if [ -f "${HERE}/lib.sh" ]; then
    source "${HERE}/lib.sh"
else
    source "${HERE}/../lib.sh"
fi

read_conf

# The settings only this script has. lib/ holds the ones it shares. After read_conf rather than
# before, as in verify.sh: a UNIPROT_VERSION in deploy.conf is the release clone.sh fetches, and
# which database to load is said here or is the newest.

# Which database to load. Empty means the newest one under OUTPUT_DIR.
UNIPROT_VERSION=

# Rows to pass over, to continue a load that stopped part way. Handed to opensearch/load.sh, which
# then keeps the index as it is rather than recreating it.
SKIP_ROWS=

# Whether to only say if the version is loaded to the end, and load nothing. What distribute.sh asks
# a server before it relies on its index.
CHECK=false

# The database before it is loaded, and so before anything can switch to it: proteins loaded from a
# database the API cannot serve would pair with files that are not there. Every check runs, and each
# problem is counted.
preflight() {
    local problems=0

    if check_db_present "$DATABASE_DIR"; then
        check_db_whole "$DATABASE_DIR" || problems=$((problems + 1))
        check_db_table "$DATABASE_DIR" || problems=$((problems + 1))
    else
        problems=$((problems + 1))
    fi
    [ "$problems" -eq 0 ] || die "${problems} problem(s), so nothing was loaded."
}

usage() {
    cat <<'USAGE'
Loads the proteins of a finished database into this host's OpenSearch.

  bin/load.sh [OPTIONS]

  --uniprot-version YYYY-MM  load this one under OUTPUT_DIR, default the newest there
  --output-dir DIR           where the databases are
  --opensearch-url URL       the instance the proteins are loaded into
  --skip ROWS                continue a load that stopped part way, passing over this many rows
  --check                    load nothing: exit 0 if the version is loaded to the end, 1 if not,
                             and 2 if OpenSearch does not say
  --help                     print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib/ and in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uniprot-version) need_value "$1" "${2-}"; valid_version "$2"; UNIPROT_VERSION="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --skip) need_value "$1" "${2-}"; SKIP_ROWS="$2"; shift 2 ;;
            --check) CHECK=true; shift ;;
            --help) usage; exit 0 ;;
            *) unknown_option "$1" ;;
        esac
    done

    # As the loader checks it too, but before the locks and the checks of what is served, rather
    # than after them.
    [ -z "$SKIP_ROWS" ] || [[ "$SKIP_ROWS" =~ ^[0-9]+$ ]] || die "--skip takes a number of rows, not '${SKIP_ROWS}'."
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."

[ -n "$UNIPROT_VERSION" ] || UNIPROT_VERSION=$(latest_version)
DATABASE_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
ENTRIES="${DATABASE_DIR}/${ENTRIES_TABLE}"
INDEX_NAME="uniprot_entries-${UNIPROT_VERSION}"

# The loader's answer, passed on: 0 loaded to the end, 1 not, and 2 where OpenSearch did not say,
# which the loader has already reported.
if [ "$CHECK" = true ]; then
    status=0
    "${DEPLOY_DIR}/../opensearch/load.sh" --opensearch-url "$OPENSEARCH_URL" --index-name "$INDEX_NAME" --check-complete || status=$?
    case $status in
        0) echo "${INDEX_NAME} is loaded to the end." ;;
        1) echo "${INDEX_NAME} is not loaded, or its load did not finish." 1>&2 ;;
    esac
    exit "$status"
fi

preflight

# Held until the load ends, so switch.sh does not stop OpenSearch under it. Before what is served is
# read, so no switch moves it between the reading and the load.
require flock:util-linux
take_opensearch_lock -s || die "$(lock_refused $?)"
# And a lock of this version's own, since two loads of one version would drop each other's index.
take_load_lock "$UNIPROT_VERSION" || case $? in
    1) die "another load of ${UNIPROT_VERSION}, or a build or a clone replacing it, is running on this host. Let it finish, or stop it, first." ;;
    *) die "without its lock, two loads of ${UNIPROT_VERSION} could drop each other's index. Make it readable by $(id -un)." ;;
esac

# The version the API serves is queried while it runs, and a load into its index, from the start or
# continued with --skip, changes what it answers with nothing stopped. Where that index is whole there
# is nothing to gain; where it is missing or was not loaded to the end, the API answers from it badly
# already, and loading it is how the host gets it back.
# An error from OpenSearch is not an index that is not whole, and loading on it would drop a whole one.
if is_served "$UNIPROT_VERSION"; then
    case $(load_state "$INDEX_NAME") in
        complete) die "${UNIPROT_VERSION} is the version this host serves, and ${INDEX_NAME} is loaded to the end. Loading into it would change what the running API answers. Switch this host to another version with switch.sh first, then load it again." ;;
        unknown) die "${UNIPROT_VERSION} is the version this host serves, and OpenSearch did not say whether ${INDEX_NAME} is whole, so loading into it is not risked. Try again once it answers." ;;
    esac
fi

warn_opensearch_disk

log "Started loading UniProtKB ${UNIPROT_VERSION} into ${INDEX_NAME} at ${OPENSEARCH_URL}."
loader_arguments=(--opensearch-url "$OPENSEARCH_URL" --uniprot-entries "$ENTRIES" --index-name "$INDEX_NAME")
[ -z "$SKIP_ROWS" ] || loader_arguments+=(--skip "$SKIP_ROWS")
"${DEPLOY_DIR}/../opensearch/load.sh" "${loader_arguments[@]}"
log "Finished loading UniProtKB ${UNIPROT_VERSION} into ${INDEX_NAME}."
log "The API does not query it until this host switches to it: switch.sh --uniprot-version ${UNIPROT_VERSION}."
