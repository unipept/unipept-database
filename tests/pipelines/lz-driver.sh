#!/usr/bin/env bash
#
# Uses lz() the way create_taxon_tables does: a producer writes into the FIFO lz() hands back,
# and lz() compresses that stream to the output path.
#
#   lz-driver.sh <temp-dir> <output-file> <rows>

set -eo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/../.."

TEMP_DIR="$1"
OUTPUT_FILE="$2"
ROWS="$3"
UNIPEPT_TEMP_CONSTANT="unipept_temp"

# shellcheck source=../../scripts/generate_tables_helper.sh
source "${REPO}/scripts/generate_tables_helper.sh"

mkdir -p "${TEMP_DIR}/${UNIPEPT_TEMP_CONSTANT}"

producer() {
    local row
    for ((row = 1; row <= ROWS; row++)); do
        printf 'row\t%s\n' "$row"
    done
}

producer > "$(lz "$OUTPUT_FILE")"
