#! /usr/bin/env bash

set -eo pipefail

# Puts what the API reads beside the suffix array: the tables that pipelines/suffix-array/build.sh
# wrote, uncompressed, in datastore/, the sample data, and the .version. The compressed tables are
# removed; uniprot_entries stays, for the load into OpenSearch.

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

source "${CURRENT_LOCATION}/../lib/common.sh"

DATASTORE_TABLES=(taxons lineages interpro_entries go_terms ec_numbers proteomes)

TABLES_DIR=""
OUTPUT_DIR=""

print_help() {
  echo "Usage: $0 --tables-dir DIR --output-dir DIR"
  echo ""
  echo "Options:"
  echo "  --tables-dir  The directory build.sh wrote the tables to (required)."
  echo "  --output-dir  The directory of the suffix array (required)."
  echo "  --help        Prints this help message."
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
      --tables-dir) option_value "$1" "${2-}"; TABLES_DIR="$2"; shift 2 ;;
      --output-dir) option_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
      --help) print_help; exit 0 ;;
      *) fail "unknown option '$1'. Run with --help for the options." ;;
    esac
  done

  [ -n "$TABLES_DIR" ] || fail "--tables-dir is required."
  [ -n "$OUTPUT_DIR" ] || fail "--output-dir is required."
}

parse_arguments "$@"

checkdep lz4

mkdir -p "$OUTPUT_DIR/datastore"

for table in "${DATASTORE_TABLES[@]}"; do
  $CMD_LZ4CAT "$TABLES_DIR/$table.tsv.lz4" > "$OUTPUT_DIR/datastore/$table.tsv"
  rm "$TABLES_DIR/$table.tsv.lz4"
done

cp "$CURRENT_LOCATION/../../assets/sampledata.json" "$OUTPUT_DIR/datastore/sampledata.json"
cp "$TABLES_DIR/.version" "$OUTPUT_DIR/.version"
log "Filled the datastore."
