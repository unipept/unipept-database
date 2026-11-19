#!/usr/bin/env bash
#
# Runs the shell suites. From anywhere: tests/run-tests.sh
#
#   run-tests.sh            every suite
#   run-tests.sh lz         lz() and the compressors it starts
#   run-tests.sh shell      the helpers in pipelines/lib/common.sh
#   run-tests.sh build      pipelines/suffix-array/build.sh end to end, offline
#   run-tests.sh umgap      pipelines/umgap/build.sh end to end, offline
#   run-tests.sh opensearch opensearch/load.sh, against a real OpenSearch

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# heading and checkdep.
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

for tool in uuidgen mktemp install; do
    checkdep "$tool"
done

suite_lz() {
    heading "lz() failure suite"
    "${HERE}/pipelines/failure-suite.sh" || status=1
}

suite_shell() {
    heading "shell library suite"
    "${HERE}/shell/suite.sh" || status=1
}

suite_build() {
    heading "build suite"
    "${HERE}/pipelines/build-suite.sh" || status=1
}

suite_umgap() {
    heading "umgap build suite"
    "${HERE}/pipelines/umgap-suite.sh" || status=1
}

suite_opensearch() {
    "${HERE}/opensearch/load-suite.sh" || status=1
}

status=0

case ${1:-all} in
    all) suite_lz; suite_shell; suite_build; suite_umgap; suite_opensearch ;;
    lz | shell | build | umgap | opensearch) "suite_${1}" ;;
    *) echo "unknown suite '${1}'" >&2; exit 1 ;;
esac

exit "$status"
