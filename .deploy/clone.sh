#!/usr/bin/env bash
#
# Copies a finished database from another host. The build itself runs once, on one host; every
# other host clones the result. It loads nothing into OpenSearch; .deploy/load.sh does that. Run it
# with --help for the options.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# The settings only this script has. lib/ holds the ones it shares.

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

# Whether to only check that a copy could be made: the settings, the key, the remote host, and its
# copy of the version. What distribute.sh asks every server before it touches any.
CHECK=false

read_conf

usage() {
    cat <<'USAGE'
Copies a finished database from another host. .deploy/load.sh then loads its proteins into this
host's OpenSearch.

  .deploy/clone.sh --remote-address HOST --local-ssh-key KEY [OPTIONS]

  --remote-address HOST      the host to copy from, required
  --local-ssh-key KEY        the private key to reach it with, required
  --remote-port PORT         its SSH port
  --remote-user USER         the user to connect as
  --remote-output-dir DIR    where it keeps its databases
  --uniprot-version YYYY-MM  which database to copy, default the newest it has
  --output-dir DIR           where the copy is written
  --replace                  replace a database of that version already here
  --check                    copy nothing: check that the copy could be made, and exit 0 if so
  --help                     print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib/ and in this script.
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
            --uniprot-version) need_value "$1" "${2-}"; valid_version "$2"; UNIPROT_VERSION="$2"; shift 2 ;;
            --replace) REPLACE=true; shift ;;
            --check) CHECK=true; shift ;;
            --help) usage; exit 0 ;;
            *) unknown_option "$1" ;;
        esac
    done

    [ -n "$REMOTE_ADDRESS" ] || die "--remote-address is required."
    [ -n "$LOCAL_SSH_KEY" ] || die "--local-ssh-key is required."
    # After the options rather than with them: deploy.conf can name the version this host clones.
    [ -z "$UNIPROT_VERSION" ] || valid_version "$UNIPROT_VERSION"
}

remote_sh() {
    ssh -i "$LOCAL_SSH_KEY" -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_ADDRESS}" "$@"
}

# The newest database the remote host holds, as YYYY-MM. The remote host is the authority on what
# it built: the current UniProtKB release is not, because a build takes days and a release can
# appear while one is running.
remote_latest_version() {
    local newest
    newest=$(remote_sh "ls -1d '${REMOTE_OUTPUT_DIR}'/${DATABASE_GLOB} 2> /dev/null | sort" | tail -n 1) \
        || true

    [ -n "$newest" ] || die "found no database in ${REMOTE_OUTPUT_DIR} on ${REMOTE_ADDRESS}."
    database_version_of "$newest"
}

# The database on the remote host, before anything is copied: a database it holds incomplete, or
# under a name its .version disagrees with, is refused here rather than after hundreds of gigabytes
# of scp.
preflight_remote() {
    check_remote_db_present "$1" || die "nothing was copied (above)."
    check_remote_db_whole "$1" || die "nothing was copied (above)."
}

copy_database() {
    local staging="$1" remote_dir="$2"

    rm -rf "${staging:?}"
    mkdir -p "$staging"

    # Into a directory this script made, so the copy lands where this script expects it whatever
    # the scp back-end makes of a trailing slash.
    scp -i "$LOCAL_SSH_KEY" -P "$REMOTE_PORT" -r \
        "${REMOTE_USER}@${REMOTE_ADDRESS}:${remote_dir}" "$staging"
    log "Copied the database from ${REMOTE_ADDRESS}."
}

# The copy: what the API needs, and the table load.sh reads. A copy that stopped part way leaves files
# that exist and are short, so the checks are on content. The k-mer table alone first: a copy that
# lost it stops there, before verify_database's warning that the table is optional says otherwise.
preflight_copy() {
    local copy=$1 remote_dir=$2 problems=0

    check_copy_kept_kmer_table "$copy" "$remote_dir" || die "the copy cannot be used (above)."
    check_db_whole "$copy" || problems=$((problems + 1))
    check_db_table "$copy" || problems=$((problems + 1))
    [ "$problems" -eq 0 ] || die "the copy cannot be used (above)."
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."

require ssh scp flock:util-linux
# Before the copy rather than after it, which is hours in.
check_lock_usable "the copy" || die "nothing was copied (above)."

[ -n "$UNIPROT_VERSION" ] || UNIPROT_VERSION=$(remote_latest_version)

if [ "$CHECK" = true ]; then
    [ -r "$LOCAL_SSH_KEY" ] || die "cannot read the ssh key ${LOCAL_SSH_KEY}."
    preflight_remote "${REMOTE_OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
    log "UniProtKB ${UNIPROT_VERSION} can be cloned from ${REMOTE_ADDRESS}."
    exit 0
fi

log "Cloning UniProtKB ${UNIPROT_VERSION} from ${REMOTE_ADDRESS}."

BUILD_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
if [ -e "$BUILD_DIR" ] && [ "$REPLACE" != true ]; then
    die "${BUILD_DIR} already exists. Pass --replace to replace it."
fi
[ ! -e "$BUILD_DIR" ] || refuse_replacing_served "$UNIPROT_VERSION" ""

# Copied here and renamed into place at the end, so a copy that fails leaves the database this
# host already serves untouched.
STAGING_DIR="${OUTPUT_DIR}/.clone"
REMOTE_DIR="${REMOTE_OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
preflight_remote "$REMOTE_DIR"
copy_database "$STAGING_DIR" "$REMOTE_DIR"

COPIED_DIR="${STAGING_DIR}/uniprot-${UNIPROT_VERSION}"
preflight_copy "$COPIED_DIR" "$REMOTE_DIR"

# Again, since the copy took hours in which this host may have switched to the version. Under the
# lock a switch holds, so none can start between this and the swap, waited for rather than given up
# on, since giving up would throw the copy away. The copy is removed where it cannot be used: it is
# hundreds of gigabytes, and the next clone.sh starts one of its own.
if ! take_opensearch_lock -s "$LOCK_WAIT"; then
    refused=$(lock_refused $?)
    rm -rf "${STAGING_DIR:?}"
    die "${refused} Waited ${LOCK_WAIT} seconds for it. The copy is removed; the next clone.sh copies again."
fi
# And no load of this version reads the table this replaces.
if ! take_load_lock "$UNIPROT_VERSION"; then
    rm -rf "${STAGING_DIR:?}"
    die "a load of ${UNIPROT_VERSION} is running on this host, and reads the files this would replace. The copy is removed; clone once it has finished."
fi
if [ -e "$BUILD_DIR" ] && is_served "$UNIPROT_VERSION"; then
    rm -rf "${STAGING_DIR:?}"
    die "${UNIPROT_VERSION} is the version this host serves, so its files are not replaced under the running API. The copy is removed. Switch this host to another version with switch.sh first."
fi
swap_into_place "$COPIED_DIR" "$BUILD_DIR"
rm -rf "${STAGING_DIR:?}"

log "The database is ready in ${BUILD_DIR}. Load its proteins with: ${HERE}/load.sh --uniprot-version ${UNIPROT_VERSION}"
