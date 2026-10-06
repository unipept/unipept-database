#!/usr/bin/env bash
#
# Checks a finished database against what the API needs, and reports everything that is wrong
# rather than the first thing. Run it with --help for the options.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

read_conf

# The settings only this script has. lib/ holds the ones it shares. After read_conf rather than
# before: a UNIPROT_VERSION in deploy.conf is the release clone.sh fetches, not the one to check, so
# it takes no part here.

# Which database to check. Empty means the newest one under OUTPUT_DIR.
UNIPROT_VERSION=

# A directory to check instead of one under OUTPUT_DIR. It is the directory the API is pointed at,
# so the index files are directly inside it.
INDEX_DIR=

usage() {
    cat <<'USAGE'
Checks a finished database against the files the API needs, and reports everything that is wrong.

  .deploy/verify.sh [OPTIONS]

  --index-dir DIR            the directory the API is pointed at, checked as it is
  --uniprot-version YYYY-MM  check this one under OUTPUT_DIR, default the newest there
  --output-dir DIR           where the databases are
  --help                     print this message

Exits 0 when every required file is there and has content, 1 when any is missing, empty or
unreadable, and 3 when the database is not there at all. A missing optional file is a warning and
does not change the exit status.

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib/ and in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --index-dir) need_value "$1" "${2-}"; INDEX_DIR="$2"; shift 2 ;;
            --uniprot-version) need_value "$1" "${2-}"; valid_version "$2"; UNIPROT_VERSION="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) unknown_option "$1" ;;
        esac
    done

    [ -z "$INDEX_DIR" ] || [ -z "$UNIPROT_VERSION" ] \
        || die "--index-dir and --uniprot-version name two different databases."
}

parse_arguments "$@"
refuse_root

# What has to be there at all for this to be a database that is broken rather than one that is not
# there: the version's directory, or the directory given.
DATABASE_DIR="$INDEX_DIR"
if [ -z "$INDEX_DIR" ]; then
    [ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
    [ -n "$UNIPROT_VERSION" ] || UNIPROT_VERSION=$(latest_version)
    DATABASE_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
    INDEX_DIR="${DATABASE_DIR}/suffix-array"
fi

echo "Checking ${INDEX_DIR}"

# Its own status, so a caller such as distribute.sh can tell a database to copy from one to leave
# alone without reading the wording.
if [ ! -e "$DATABASE_DIR" ]; then
    echo "FAIL ${DATABASE_DIR} is not there" 1>&2
    exit 3
fi

status=0
check_index_files "$INDEX_DIR" || status=1
check_index_version "$INDEX_DIR" || status=1

# Only in a directory it could look in: check_index_files has already said why it could not.
if [ -s "${INDEX_DIR}/build-info.txt" ]; then
    sed 's/^/  /' "${INDEX_DIR}/build-info.txt"
elif [ -d "$INDEX_DIR" ] && [ -x "$INDEX_DIR" ]; then
    echo "WARN build-info.txt is missing; nothing records what this database was built from" 1>&2
fi

if [ "$status" -eq 0 ]; then
    echo "The database has every file the API needs."
else
    echo "The database is not complete." 1>&2
fi

exit "$status"
