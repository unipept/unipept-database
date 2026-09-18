#!/usr/bin/env bash
#
# Uses luz() with a reader that stops after the first row, as `head` does.
#
#   luz-driver.sh <temp-dir> <input-file>

set -eo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/../.."

TEMP_DIR="$1"
INPUT_FILE="$2"
UNIPEPT_TEMP_CONSTANT="unipept_temp"

# shellcheck source=../../scripts/generate_tables_helper.sh
source "${REPO}/scripts/generate_tables_helper.sh"

trap errorAndExit ERR

mkdir -p "${TEMP_DIR}/${UNIPEPT_TEMP_CONSTANT}"

head -n 1 "$(luz "$INPUT_FILE")" > /dev/null

wait_for_writers
