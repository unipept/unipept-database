#!/usr/bin/env bash
#
# Runs the shell suites. From anywhere: tests/run-tests.sh
#
#   run-tests.sh            every suite
#   run-tests.sh lz         lz() and the compressors it starts
#   run-tests.sh shell      the helpers in pipelines/lib/common.sh
#   run-tests.sh build      pipelines/suffix-array/build.sh end to end, offline
#   run-tests.sh opensearch opensearch/load.sh, against a real OpenSearch
#   run-tests.sh verify     .deploy/verify.sh against a fixture index
#   run-tests.sh deploy     .deploy/build.sh and clone.sh, in a container
#   run-tests.sh seam       .deploy/build.sh over the real pipeline, offline

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../pipelines/lib/common.sh
source "${HERE}/../pipelines/lib/common.sh"

heading() { printf '\n\033[1m%s\033[0m\n' "$*"; }

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

suite_opensearch() {
    "${HERE}/opensearch/load-suite.sh" || status=1
}

suite_verify() {
    heading "verify suite"
    "${HERE}/deploy/verify-suite.sh" || status=1
}

suite_deploy() {
    "${HERE}/deploy/build-suite.sh" || status=1
}

suite_seam() {
    heading "deploy over the real pipeline"
    "${HERE}/deploy/pipeline-suite.sh" || status=1
}

status=0

case ${1:-all} in
    all) suite_lz; suite_shell; suite_verify; suite_build; suite_seam; suite_deploy; suite_opensearch ;;
    lz | shell | verify | build | seam | deploy | opensearch) "suite_${1}" ;;
    *) echo "unknown suite '${1}'" >&2; exit 1 ;;
esac

exit "$status"
