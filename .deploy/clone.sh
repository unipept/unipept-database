#!/usr/bin/env bash
#
# Copies a finished database from another host and loads its proteins into this host's OpenSearch.
# The build itself runs once, on one host; every other host clones the result.
#
#   .deploy/clone.sh --remote-address HOST --local-ssh-key KEY [--output-dir DIR]
#
# Settings come from the environment, then .deploy/build.conf, then the defaults in lib.sh.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote-address) REMOTE_ADDRESS="$2"; shift 2 ;;
            --remote-port) REMOTE_PORT="$2"; shift 2 ;;
            --remote-user) REMOTE_USER="$2"; shift 2 ;;
            --remote-output-dir) REMOTE_OUTPUT_DIR="$2"; shift 2 ;;
            --local-ssh-key) LOCAL_SSH_KEY="$2"; shift 2 ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --opensearch-url) OPENSEARCH_URL="$2"; shift 2 ;;
            --help) sed -n '2,9p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [ -n "$REMOTE_ADDRESS" ] || die "--remote-address is required."
    [ -n "$LOCAL_SSH_KEY" ] || die "--local-ssh-key is required."
}

copy_database() {
    local build_dir="$1" remote_dir="$2"

    ssh -i "$LOCAL_SSH_KEY" -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_ADDRESS}" "[ -d '${remote_dir}' ]" \
        || die "the remote host has no ${remote_dir}"

    rm -rf "${build_dir:?}"
    scp -i "$LOCAL_SSH_KEY" -P "$REMOTE_PORT" -r \
        "${REMOTE_USER}@${REMOTE_ADDRESS}:${remote_dir}" "${OUTPUT_DIR:?}"
    log "Copied the database from ${REMOTE_ADDRESS}."
}

load_opensearch() {
    local build_dir="$1"

    log "Started loading the proteins into OpenSearch."
    "${HERE}/../opensearch/load.sh" \
        --opensearch-url "$OPENSEARCH_URL" \
        --uniprot-entries "${build_dir}/tables/uniprot_entries.tsv.lz4"
    log "Finished loading the proteins into OpenSearch."
}

parse_arguments "$@"

checkdep curl
checkdep lz4
checkdep ssh
checkdep scp

UNIPROT_VERSION=$(latest_uniprot_version)
log "UniProtKB version is ${UNIPROT_VERSION}."

BUILD_DIR="${OUTPUT_DIR:?}/uniprot-${UNIPROT_VERSION}"

copy_database "$BUILD_DIR" "${REMOTE_OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}/"
load_opensearch "$BUILD_DIR"

log "The database is ready in ${BUILD_DIR}."
