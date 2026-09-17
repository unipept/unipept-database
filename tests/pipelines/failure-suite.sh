#!/usr/bin/env bash
#
# lz() hands a FIFO to a producer and compresses what arrives on it, in the background. This
# suite covers what happens when that compressor fails or is slow, which is the one path the
# pipeline never exercises on a good run.
#
# The cases run against the real lz() in scripts/generate_tables_helper.sh with a stand-in lz4
# on PATH, so they need no compression tool and no network.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

BIN="${WORK}/bin"
mkdir -p "${BIN}"
install -m 755 "${HERE}/stub-lz4.sh" "${BIN}/lz4"
export PATH="${BIN}:${PATH}"

rc=0

# Runs the driver once with the stand-in in the given mode. Leaves the exit status in `rc` and
# everything the run said in ${WORK}/stderr.
run_driver() {
    local mode=$1 output=$2

    rm -rf "${WORK}/temp"
    mkdir -p "${WORK}/temp"
    : > "${WORK}/stderr"

    STUB_LZ4_MODE="$mode" "${HERE}/lz-driver.sh" "${WORK}/temp" "$output" 200 2> "${WORK}/stderr"
    rc=$?
}

status_of() { if [ "$1" -eq 0 ]; then echo zero; else echo non-zero; fi; }
presence_of() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
names_file() { if grep -q -- "$(basename "$1")" "${WORK}/stderr"; then echo named; else echo "not named"; fi; }


section "a compressor that fails after the producer has finished"
output="${WORK}/late.tsv.lz4"
run_driver late "$output"
check "the build reports a failure" "$(status_of "$rc")" "non-zero"
check "the failure names the table" "$(names_file "$output")" "named"
check "no partial table is left behind" "$(presence_of "$output")" "absent"


section "a compressor that fails before it reads anything"
output="${WORK}/early.tsv.lz4"
run_driver early "$output"
check "the build reports a failure" "$(status_of "$rc")" "non-zero"
check "the failure names the table" "$(names_file "$output")" "named"
check "no partial table is left behind" "$(presence_of "$output")" "absent"


section "a compressor still writing when the producer has finished"
output="${WORK}/slow.tsv.lz4"
run_driver slow "$output"
check "the build succeeds" "$(status_of "$rc")" "zero"
check "the table holds every row the producer wrote" "$(wc -l < "$output" 2> /dev/null | tr -d ' ')" "200"


summary
