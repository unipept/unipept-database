#!/usr/bin/env bash
#
# Checks a finished database against what the API needs, and reports everything that is wrong
# rather than the first thing. Run it with --help for the options.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

read_conf

# The settings only this script has. lib.sh holds the two both other scripts have. After read_conf
# rather than before: a UNIPROT_VERSION in deploy.conf is the release clone.sh fetches, not the one
# to check, so it takes no part here.

# Which database to check. Empty means the newest one under OUTPUT_DIR.
UNIPROT_VERSION=

# A directory to check instead of one under OUTPUT_DIR. It is the directory the API is pointed at,
# so the index files are directly inside it.
INDEX_DIR=

usage() {
    cat <<'USAGE'
Checks a finished database against the files the API needs, and reports everything that is wrong.

  .deploy/verify.sh [OPTIONS]

  --index-dir DIR          the directory the API is pointed at, checked as it is
  --uniprot-version YYYY-MM  check this one under OUTPUT_DIR, default the newest there
  --output-dir DIR         where the databases are
  --help                   print this message

Exits 0 when every required file is there and has content, and 1 when any is missing, empty or
unreadable. A missing optional file is a warning and does not change the exit status.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --index-dir) need_value "$1" "${2-}"; INDEX_DIR="$2"; shift 2 ;;
            --uniprot-version) need_value "$1" "${2-}"; UNIPROT_VERSION="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [ -z "$INDEX_DIR" ] || [ -z "$UNIPROT_VERSION" ] \
        || die "--index-dir and --uniprot-version name two different databases."
}

# The newest database under OUTPUT_DIR, as YYYY-MM. The glob expands in order, so the last one
# that is a directory is the newest.
latest_version() {
    local newest='' candidate

    # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
    for candidate in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
        [ -d "$candidate" ] && newest="$candidate"
    done

    [ -n "$newest" ] || die "found no database in ${OUTPUT_DIR}."
    database_version_of "$newest"
}

parse_arguments "$@"
refuse_root

if [ -z "$INDEX_DIR" ]; then
    [ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
    [ -n "$UNIPROT_VERSION" ] || UNIPROT_VERSION=$(latest_version)
    INDEX_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}/suffix-array"
fi

echo "Checking ${INDEX_DIR}"

status=0
verify_database "$INDEX_DIR" || status=1

if [ -s "${INDEX_DIR}/build-info.txt" ]; then
    sed 's/^/  /' "${INDEX_DIR}/build-info.txt"
else
    echo "WARN build-info.txt is missing; nothing records what this database was built from" 1>&2
fi

if [ "$status" -eq 0 ]; then
    echo "The database has every file the API needs."
else
    echo "The database is not complete." 1>&2
fi

exit "$status"
