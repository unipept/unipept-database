#! /usr/bin/env bash

set -eo pipefail

# Builds the suffix array the API searches from the uniprot_entries table that
# pipelines/suffix-array/build.sh writes. sa.bin, proteins.bin, mapping.bin and kmer_table.bin go
# to the output directory.

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

source "${CURRENT_LOCATION}/../lib/common.sh"

# Not options: an index built with other values still looks valid to the API, so a mistake here is
# only visible in what it serves.
SPARSENESS_FACTOR=2
CONSTRUCTION_ALGORITHM=lib-sais

# The API uses the k-mer table when it is there. Without it every search reads the whole suffix
# array. The table is about 127 MB at k=5, whatever the size of the database.
KMER_SIZE=5

UNIPROT_ENTRIES=""
OUTPUT_DIR=""

print_help() {
  echo "Usage: $0 --uniprot-entries FILE --output-dir DIR"
  echo ""
  echo "Options:"
  echo "  --uniprot-entries  The uniprot_entries.tsv.lz4 to index (required)."
  echo "  --output-dir       Directory to save the index files (required)."
  echo "  --help             Prints this help message."
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
      --uniprot-entries) option_value "$1" "${2-}"; UNIPROT_ENTRIES="$2"; shift 2 ;;
      --output-dir) option_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
      --help) print_help; exit 0 ;;
      *) fail "unknown option '$1'. Run with --help for the options." ;;
    esac
  done

  [ -n "$UNIPROT_ENTRIES" ] || fail "--uniprot-entries is required."
  [ -n "$OUTPUT_DIR" ] || fail "--output-dir is required."
  [ -r "$UNIPROT_ENTRIES" ] || fail "cannot read $UNIPROT_ENTRIES."
}

parse_arguments "$@"

checkdep lz4
checkdep sa-builder "sa-builder from unipept-index"

mkdir -p "$OUTPUT_DIR"

# About 100 GB on full UniProt, and read by nothing after sa-builder.
PROTEINS="$OUTPUT_DIR/proteins.tsv"
trap 'rm -f "$PROTEINS"' EXIT

# The four columns sa-builder reads: accession, taxon, sequence, annotations.
$CMD_LZ4CAT "$UNIPROT_ENTRIES" | cut -f2,4,7,8 > "$PROTEINS"

log "Started building the suffix array."
sa-builder \
  --database-file "$PROTEINS" \
  --output-sa "$OUTPUT_DIR/sa.bin" \
  --output-proteins "$OUTPUT_DIR/proteins.bin" \
  --output-mapping "$OUTPUT_DIR/mapping.bin" \
  --output-kmer-table "$OUTPUT_DIR/kmer_table.bin" \
  --kmer-size "$KMER_SIZE" \
  --sparseness-factor "$SPARSENESS_FACTOR" \
  --construction-algorithm "$CONSTRUCTION_ALGORITHM" \
  --compress-sa
log "Finished building the suffix array."
