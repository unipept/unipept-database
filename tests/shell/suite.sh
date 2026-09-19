#!/usr/bin/env bash
#
# The helpers in pipelines/lib/common.sh that need no network and no container. Needs gawk and lz4.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

TEMP_DIR="$(mktemp -d)"
UNIPEPT_TEMP_CONSTANT="unipept_temp"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# shellcheck source=../../pipelines/lib/common.sh
source "${HERE}/../../pipelines/lib/common.sh"

mkdir -p "${TEMP_DIR}/${UNIPEPT_TEMP_CONSTANT}"
touch "${TEMP_DIR}/present"


section "have"
check_true "every file exists" have "${TEMP_DIR}/present" "${TEMP_DIR}/present"
have "${TEMP_DIR}/present" "${TEMP_DIR}/absent"
check "a missing file fails" "$?" "1"
check_true "no files at all passes" have


section "collapse"
check "the values of one key are joined" "$(printf 'A\t1\nA\t2\nB\t3\n' | collapse)" "$(printf 'A\t1;2\nB\t3')"
check "no input gives no output" "$(printf '' | collapse)" ""


section "lz and luz"
table="${TEMP_DIR}/tables/numbers.tsv.lz4"
seq 1 1000 > "$(lz "$table")"
check_true "lz reports no failure" wait_for_writers
check "the table is lz4" "$(lz4 -dc "$table" | head -n 1)" "1"
check "luz reads every row back" "$(wc -l < "$(luz "$table")" | tr -d ' ')" "1000"
check_true "luz reports no failure" wait_for_writers


section "checkDirectoryAndCreate"
checkDirectoryAndCreate "${TEMP_DIR}/new/directory"
check_true "a missing directory is created" test -d "${TEMP_DIR}/new/directory"
(checkDirectoryAndCreate "${TEMP_DIR}/present" 2> /dev/null)
check "a file is refused" "$?" "4"


summary
