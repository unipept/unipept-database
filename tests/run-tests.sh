#!/usr/bin/env bash
#
# Runs the shell suites. From anywhere: tests/run-tests.sh
#
#   run-tests.sh            every suite
#   run-tests.sh lz         lz() and the compressors it starts

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n\033[1m%s\033[0m\n' "$*"; }

for tool in uuidgen mktemp install; do
    command -v "$tool" > /dev/null || { echo "${tool} is not installed" >&2; exit 1; }
done

suite_lz() {
    log "lz() failure suite"
    "${HERE}/pipelines/failure-suite.sh" || status=1
}

status=0

case ${1:-all} in
    all | lz) suite_lz ;;
    *) echo "unknown suite '${1}'" >&2; exit 1 ;;
esac

exit "$status"
