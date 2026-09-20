#!/usr/bin/env bash
#
# Copies a finished database from another host and loads its proteins into this host's OpenSearch.
# The build itself runs once, on one host; every other host clones the result. Run it with --help
# for the options.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR

# The settings only this script has. lib.sh holds the two both scripts have.

# The host a finished database is copied from.
REMOTE_ADDRESS=
REMOTE_PORT=4840
REMOTE_USER=unipept
REMOTE_OUTPUT_DIR=/mnt/data
LOCAL_SSH_KEY=

# Which database to copy. Empty means the newest one the remote host has.
UNIPROT_VERSION=

# Whether a database of that version already here may be replaced.
REPLACE=false

read_conf

usage() {
    cat <<'USAGE'
Copies a finished database from another host and loads its proteins into this host's OpenSearch.

  .deploy/clone.sh --remote-address HOST --local-ssh-key KEY [OPTIONS]

  --remote-address HOST    the host to copy from, required
  --local-ssh-key KEY      the private key to reach it with, required
  --remote-port PORT       its SSH port
  --remote-user USER       the user to connect as
  --remote-output-dir DIR  where it keeps its databases
  --uniprot-version YYYY-MM  which database to copy, default the newest it has
  --output-dir DIR         where the copy is written
  --opensearch-url URL     the instance the proteins are loaded into
  --replace                replace a database of that version already here
  --help                   print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib.sh and in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote-address) need_value "$1" "${2-}"; REMOTE_ADDRESS="$2"; shift 2 ;;
            --remote-port) need_value "$1" "${2-}"; REMOTE_PORT="$2"; shift 2 ;;
            --remote-user) need_value "$1" "${2-}"; REMOTE_USER="$2"; shift 2 ;;
            --remote-output-dir) need_value "$1" "${2-}"; REMOTE_OUTPUT_DIR="$2"; shift 2 ;;
            --local-ssh-key) need_value "$1" "${2-}"; LOCAL_SSH_KEY="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --uniprot-version) need_value "$1" "${2-}"; UNIPROT_VERSION="$2"; shift 2 ;;
            --replace) REPLACE=true; shift ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [ -n "$REMOTE_ADDRESS" ] || die "--remote-address is required."
    [ -n "$LOCAL_SSH_KEY" ] || die "--local-ssh-key is required."
}

remote_sh() {
    ssh -i "$LOCAL_SSH_KEY" -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_ADDRESS}" "$@"
}

# The newest database the remote host holds, as YYYY-MM. The remote host is the authority on what
# it built: the current UniProtKB release is not, because a build takes days and a release can
# appear while one is running.
remote_latest_version() {
    local newest
    newest=$(remote_sh "ls -1d '${REMOTE_OUTPUT_DIR}'/uniprot-* 2> /dev/null | sort" | tail -n 1) \
        || true

    [ -n "$newest" ] || die "found no database in ${REMOTE_OUTPUT_DIR} on ${REMOTE_ADDRESS}."

    newest="${newest##*/}"
    echo "${newest#uniprot-}"
}

copy_database() {
    local staging="$1" version="$2"
    local remote_dir="${REMOTE_OUTPUT_DIR}/uniprot-${version}"

    remote_sh "[ -d '${remote_dir}' ]" || die "the remote host has no ${remote_dir}"

    rm -rf "${staging:?}"
    mkdir -p "$staging"

    # Into a directory this script made, so the copy lands where this script expects it whatever
    # the scp back-end makes of a trailing slash.
    scp -i "$LOCAL_SSH_KEY" -P "$REMOTE_PORT" -r \
        "${REMOTE_USER}@${REMOTE_ADDRESS}:${remote_dir}" "$staging"
    log "Copied the database from ${REMOTE_ADDRESS}."
}

# What the API needs, and the table clone.sh itself reads. A copy that stopped part way leaves
# files that exist and are short, so the check is on content.
check_database() {
    local dir="$1" file

    for file in suffix-array/sa.bin suffix-array/proteins.bin suffix-array/mapping.bin \
        suffix-array/.version tables/uniprot_entries.tsv.lz4; do
        [ -s "${dir}/${file}" ] || die "the copied database has no ${file}"
    done
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

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."

checkdep ssh
checkdep scp
check_loader_deps

[ -n "$UNIPROT_VERSION" ] || UNIPROT_VERSION=$(remote_latest_version)
log "Cloning UniProtKB ${UNIPROT_VERSION} from ${REMOTE_ADDRESS}."

BUILD_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
if [ -e "$BUILD_DIR" ] && [ "$REPLACE" != true ]; then
    die "${BUILD_DIR} already exists. Pass --replace to replace it."
fi

# Copied here and renamed into place at the end, so a copy that fails leaves the database this
# host already serves untouched.
STAGING_DIR="${OUTPUT_DIR}/.clone"
copy_database "$STAGING_DIR" "$UNIPROT_VERSION"

COPIED_DIR="${STAGING_DIR}/uniprot-${UNIPROT_VERSION}"
check_database "$COPIED_DIR"

load_opensearch "$COPIED_DIR"

swap_into_place "$COPIED_DIR" "$BUILD_DIR"
rm -rf "${STAGING_DIR:?}"

log "The database is ready in ${BUILD_DIR}."
