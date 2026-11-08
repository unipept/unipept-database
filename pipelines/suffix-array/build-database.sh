#! /usr/bin/env bash

set -eo pipefail

# Builds a whole database in OUTPUT_DIR/uniprot-<YYYY-MM>: tables/ with the entries for OpenSearch,
# and suffix-array/, the directory the API reads. It builds in OUTPUT_DIR/.build and renames that
# at the end, so the database directory only exists when it is complete. It loads nothing into
# OpenSearch; opensearch/load.sh does that.

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

source "${CURRENT_LOCATION}/../lib/common.sh"

DATABASE_SOURCES="swissprot,trembl"
OUTPUT_DIR=""

print_help() {
  echo "Usage: $0 --output-dir DIR [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --output-dir        Directory that holds the databases (required)."
  echo "  --database-sources  Comma-separated list of database sources ('swissprot', 'trembl'), (optional, default: 'swissprot,trembl')."
  echo "  --help              Prints this help message."
  echo ""
  echo "build-info.txt records the commits in UNIPEPT_DATABASE_COMMIT and UNIPEPT_INDEX_COMMIT, which the image sets."
  echo ""
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

option_value() {
  [ -n "${2-}" ] || fail "$1 requires a value."
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir) option_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
      --database-sources) option_value "$1" "${2-}"; DATABASE_SOURCES="$2"; shift 2 ;;
      --help) print_help; exit 0 ;;
      *) fail "unknown option '$1'. Run with --help for the options." ;;
    esac
  done

  [ -n "$OUTPUT_DIR" ] || fail "--output-dir is required."
}

parse_arguments "$@"

# The tables take hours, and sa-builder runs after them.
checkdep sa-builder "sa-builder from unipept-index"

STAGING="$OUTPUT_DIR/.build"
rm -rf "${STAGING:?}"
mkdir -p "$STAGING"/{tables,suffix-array,temp}

"$CURRENT_LOCATION/build.sh" \
  --database-sources "$DATABASE_SOURCES" \
  --output-dir "$STAGING/tables" \
  --temp-dir "$STAGING/temp"

"$CURRENT_LOCATION/build-index.sh" \
  --uniprot-entries "$STAGING/tables/uniprot_entries.tsv.lz4" \
  --output-dir "$STAGING/suffix-array"

"$CURRENT_LOCATION/fill-datastore.sh" \
  --tables-dir "$STAGING/tables" \
  --output-dir "$STAGING/suffix-array"

# An archive of an empty stream has bytes, so the files are tested after it is unpacked.
for file in \
  "$STAGING/tables/uniprot_entries.tsv.lz4" \
  "$STAGING"/suffix-array/{.version,sa.bin,proteins.bin,mapping.bin,kmer_table.bin} \
  "$STAGING"/suffix-array/datastore/*
do
  [ -s "$file" ] || fail "$file is missing or empty. The build is in $STAGING."
done

# .version holds YYYY.MM, which the API reads. The directory name uses dashes.
VERSION=$(tr -d '[:space:]' < "$STAGING/suffix-array/.version" | tr '.' '-')
[[ "$VERSION" =~ ^[0-9]{4}-[0-9]{2}$ ]] || fail "the tables name the version '$VERSION', not YYYY-MM. The build is in $STAGING."

TARGET="$OUTPUT_DIR/uniprot-$VERSION"
[ ! -e "$TARGET" ] || fail "$TARGET already exists. The build is in $STAGING."

cat > "$STAGING/suffix-array/build-info.txt" <<INFO
built: $(date -u +'%F %T UTC')
uniprot: ${VERSION}
unipept-database: ${UNIPEPT_DATABASE_COMMIT:-unknown}
unipept-index: ${UNIPEPT_INDEX_COMMIT:-unknown}
sources: ${DATABASE_SOURCES}
INFO

rm -rf "$STAGING/temp"
mv "$STAGING" "$TARGET"

log "The database is ready in $TARGET. Load its proteins into uniprot_entries-$VERSION with opensearch/load.sh."
