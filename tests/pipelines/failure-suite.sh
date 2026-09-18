#!/usr/bin/env bash
#
# lz() hands a FIFO to a producer and compresses what arrives on it, in the background. This
# suite covers what happens when that compressor fails or is slow, which is the one path the
# pipeline never exercises on a good run.
#
# The cases run against the real lz() in pipelines/lib/common.sh with a stand-in lz4
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

    STUB_LZ4_MODE="$mode" "${HERE}/lz-driver.sh" "${WORK}/temp" "$output" 200 2> "${WORK}/stderr"
    rc=$?
}

# A compressor that fails must fail the build, be named in the error, and leave no partial table.
expect_failure() {
    local mode=$1 output="${WORK}/$1.tsv.lz4"

    section "$2"
    run_driver "$mode" "$output"
    check_true "the build reports a failure" [ "$rc" -ne 0 ]
    check_true "the failure names the table" grep -q -- "$(basename "$output")" "${WORK}/stderr"
    check_true "no partial table is left behind" [ ! -e "$output" ]
}


expect_failure late "a compressor that fails after the producer has finished"
expect_failure early "a compressor that fails before it reads anything"


section "a compressor still writing when the producer has finished"
output="${WORK}/slow.tsv.lz4"
run_driver slow "$output"
check_true "the build succeeds" [ "$rc" -eq 0 ]
check "the table holds every row the producer wrote" "$(wc -l < "$output" 2> /dev/null | tr -d ' ')" "200"


# Runs luz-driver.sh with the stand-in in the given mode. Leaves the exit status in `rc`.
run_reader() {
    rm -rf "${WORK}/temp"
    : > "${WORK}/input.tsv.lz4"
    STUB_LZ4_MODE="$1" "${HERE}/luz-driver.sh" "${WORK}/temp" "${WORK}/input.tsv.lz4" 2> "${WORK}/stderr"
    rc=$?
}

section "a reader that stops before the end of a decompressed table"
run_reader endless
check_true "the build succeeds" [ "$rc" -eq 0 ]

section "a decompressor that fails"
run_reader early
check_true "the build reports a failure" [ "$rc" -ne 0 ]


summary
