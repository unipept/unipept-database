#!/usr/bin/env bash
#
# Copies a finished database from another host. The build itself runs once, on one host; every
# other host clones the result. It loads nothing into OpenSearch; .deploy/load.sh does that. Run it
# with --help for the options.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR

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

  --remote-address HOST    the host to copy from, required
  --local-ssh-key KEY      the private key to reach it with, required
  --remote-port PORT       its SSH port
  --remote-user USER       the user to connect as
  --remote-output-dir DIR  where it keeps its databases
  --uniprot-version YYYY-MM  which database to copy, default the newest it has
  --output-dir DIR         where the copy is written
  --replace                replace a database of that version already here
  --check                  copy nothing: check that the copy could be made, and exit 0 if so
  --help                   print this message

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
            --uniprot-version) need_value "$1" "${2-}"; UNIPROT_VERSION="$2"; shift 2 ;;
            --replace) REPLACE=true; shift ;;
            --check) CHECK=true; shift ;;
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
    newest=$(remote_sh "ls -1d '${REMOTE_OUTPUT_DIR}'/${DATABASE_GLOB} 2> /dev/null | sort" | tail -n 1) \
        || true

    [ -n "$newest" ] || die "found no database in ${REMOTE_OUTPUT_DIR} on ${REMOTE_ADDRESS}."
    database_version_of "$newest"
}

# The same checks the copy gets afterwards, run on the remote host before anything is copied. A
# database the remote holds incomplete, or under a name its .version disagrees with, is refused here
# rather than after hundreds of gigabytes of scp. The functions and the lists they read are sent
# along, so both sides check against this checkout's contract.
check_remote_database() {
    local remote_dir="$1"

    remote_sh "[ -d '${remote_dir}' ]" || die "the remote host has no ${remote_dir}"

    remote_sh bash -s <<REMOTE || die "the database on ${REMOTE_ADDRESS} is missing files the API needs, or is not the version it is named after."
$(verify_database_source)
status=0
verify_database '${remote_dir}/suffix-array' || status=1
[ -s '${remote_dir}/tables/uniprot_entries.tsv.lz4' ] || { echo "FAIL tables/uniprot_entries.tsv.lz4 is missing" 1>&2; status=1; }
exit "\$status"
REMOTE
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

# What the API needs, and the table clone.sh itself reads. A copy that stopped part way leaves
# files that exist and are short, so the check is on content.
check_database() {
    local dir="$1" remote_dir="$2"

    # The k-mer table is an accelerator the API runs without, so a database built before build.sh
    # wrote one has none and is still worth cloning. The remote decides: one the remote has and the
    # copy does not is a copy that lost it. Before verify_database, whose warning that the table is
    # optional would otherwise precede the error that says it is not. test answers 0 or 1; anything
    # else is ssh failing, which says nothing about the table.
    local remote_has_kmer=0
    remote_sh "[ -s '${remote_dir}/suffix-array/kmer_table.bin' ]" || remote_has_kmer=$?
    case "$remote_has_kmer" in
        0) [ -s "${dir}/suffix-array/kmer_table.bin" ] \
            || die "the remote has a k-mer table and the copy does not" ;;
        1) ;;
        *) die "could not ask ${REMOTE_ADDRESS} whether it has a k-mer table, so cannot tell whether the copy lost one." ;;
    esac

    verify_database "${dir}/suffix-array" \
        || die "the copy is missing files the API needs, or is not the version it is named after."

    # Outside the index, so not in INDEX_FILES: it is what load.sh feeds to OpenSearch.
    [ -s "${dir}/tables/uniprot_entries.tsv.lz4" ] \
        || die "the copied database has no tables/uniprot_entries.tsv.lz4"
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."

checkdep ssh
checkdep scp
checkdep flock "util-linux"
# Before the copy rather than after it, which is hours in.
opensearch_lock_usable \
    || die "cannot open the lock ${OPENSEARCH_LOCK} as $(id -un), which the copy is swapped in under. Make it writable, or set OPENSEARCH_LOCK."

[ -n "$UNIPROT_VERSION" ] || UNIPROT_VERSION=$(remote_latest_version)

if [ "$CHECK" = true ]; then
    [ -r "$LOCAL_SSH_KEY" ] || die "cannot read the ssh key ${LOCAL_SSH_KEY}."
    check_remote_database "${REMOTE_OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
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
check_remote_database "$REMOTE_DIR"
copy_database "$STAGING_DIR" "$REMOTE_DIR"

COPIED_DIR="${STAGING_DIR}/uniprot-${UNIPROT_VERSION}"
check_database "$COPIED_DIR" "$REMOTE_DIR"

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
