#! /usr/bin/env bash

set -eo pipefail

# Builds the suffix array the API searches from the uniprot_entries table that
# pipelines/suffix-array/build.sh writes. sa.bin, proteins.bin, mapping.bin and kmer_table.bin go
# to the output directory.

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

source "${CURRENT_LOCATION}/../lib/common.sh"

UNIPROT_ENTRIES=""
OUTPUT_DIR=""
SPARSENESS_FACTOR=""
KMER_SIZE=""
CONSTRUCTION_ALGORITHM=""

print_help() {
  echo "Usage: $0 --uniprot-entries FILE --output-dir DIR --sparseness-factor N --kmer-size K --construction-algorithm NAME"
  echo ""
  echo "Options (all required):"
  echo "  --uniprot-entries         The uniprot_entries.tsv.lz4 to index."
  echo "  --output-dir              Directory to save the index files."
  echo "  --sparseness-factor       Index every N-th position of the protein text."
  echo "  --kmer-size               The k of the k-mer table."
  echo "  --construction-algorithm  The algorithm sa-builder builds the suffix array with."
  echo "  --help                    Prints this help message."
  echo ""
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uniprot-entries) option_value "$1" "${2-}"; UNIPROT_ENTRIES="$2"; shift 2 ;;
      --output-dir) option_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
      --sparseness-factor) option_value "$1" "${2-}"; SPARSENESS_FACTOR="$2"; shift 2 ;;
      --kmer-size) option_value "$1" "${2-}"; KMER_SIZE="$2"; shift 2 ;;
      --construction-algorithm) option_value "$1" "${2-}"; CONSTRUCTION_ALGORITHM="$2"; shift 2 ;;
      --help) print_help; exit 0 ;;
      *) fail "unknown option '$1'. Run with --help for the options." ;;
    esac
  done

  [ -n "$UNIPROT_ENTRIES" ] || fail "--uniprot-entries is required."
  [ -n "$OUTPUT_DIR" ] || fail "--output-dir is required."
  [ -n "$SPARSENESS_FACTOR" ] || fail "--sparseness-factor is required."
  [ -n "$KMER_SIZE" ] || fail "--kmer-size is required."
  [ -n "$CONSTRUCTION_ALGORITHM" ] || fail "--construction-algorithm is required."
  [ -r "$UNIPROT_ENTRIES" ] || fail "cannot read $UNIPROT_ENTRIES."
}

parse_arguments "$@"

checkdep lz4
checkdep sa-builder "sa-builder from unipept-index"

checkDirectoryAndCreate "$OUTPUT_DIR"

log "Started building the suffix array."
# The four columns sa-builder reads: accession, taxon, sequence, annotations. Through a pipe, as a
# file would be about 100 GB on full UniProt.
$CMD_LZ4CAT "$UNIPROT_ENTRIES" | cut -f2,4,7,8 | sa-builder \
  --database-file /dev/stdin \
  --output-sa "$OUTPUT_DIR/sa.bin" \
  --output-proteins "$OUTPUT_DIR/proteins.bin" \
  --output-mapping "$OUTPUT_DIR/mapping.bin" \
  --output-kmer-table "$OUTPUT_DIR/kmer_table.bin" \
  --kmer-size "$KMER_SIZE" \
  --sparseness-factor "$SPARSENESS_FACTOR" \
  --construction-algorithm "$CONSTRUCTION_ALGORITHM" \
  --compress-sa
log "Finished building the suffix array."
