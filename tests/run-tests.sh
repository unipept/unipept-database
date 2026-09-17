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

suite=${1:-all}
status=0

if [ "$suite" = all ] || [ "$suite" = lz ]; then
    log "lz() failure suite"
    "${HERE}/pipelines/failure-suite.sh" || status=1
fi

case $suite in
    all | lz) ;;
    *) echo "unknown suite '${suite}'" >&2; exit 1 ;;
esac

exit "$status"
