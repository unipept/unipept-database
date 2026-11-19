# shellcheck shell=bash
#
# The setup the suites share, and the assertions they make. Sourced, never run.

TESTS_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"

# checkdep and the other helpers the pipelines use. Here rather than in each suite, so a suite's
# dependency checks exist whether or not it remembers to source them.
# shellcheck source=../pipelines/lib/common.sh
source "${TESTS_DIR}/../pipelines/lib/common.sh"

# check, check_true, check_absent, section and summary.
# shellcheck source=assertions.sh
source "${TESTS_DIR}/assertions.sh"

# A stand-in command: a shell script at PATH that runs BODY. Prints PATH.
make_stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$1"
    chmod +x "$1"
    echo "$1"
}

# A heading between suites, or between the steps of one.
heading() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# For the suites that start containers.
require_docker() {
    command -v docker > /dev/null || { echo "docker is not installed" >&2; exit 1; }
    docker info > /dev/null 2>&1 || { echo "the Docker daemon is not running" >&2; exit 1; }
}

# Points every source the pipeline downloads at the fixture corpus, through the UNIPEPT_*_URL
# variables pipelines/lib/sources.sh reads. The archives the pipeline expects are made in the given
# directory. A new source is added here, and every suite that runs the pipeline gets it.
use_fixture_sources() {
    local work="$1" fixtures="${TESTS_DIR}/../crates/fixtures/data" sources="${TESTS_DIR}/pipelines/sources"

    gzip -c "${fixtures}/uniprot_sprot.dat" > "${work}/uniprot_sprot.dat.gz" || return 1
    (cd "$fixtures" && zip -q "${work}/taxdmp.zip" names.dmp nodes.dmp) || return 1

    export UNIPEPT_SWISSPROT_URL="file://${work}/uniprot_sprot.dat.gz"
    export UNIPEPT_TAXDMP_URL="file://${work}/taxdmp.zip"
    export UNIPEPT_RELEASE_METALINK_URL="file://${sources}/RELEASE.metalink"
    export UNIPEPT_EC_CLASS_URL="file://${sources}/enzclass.txt"
    export UNIPEPT_EC_NUMBER_URL="file://${sources}/enzyme.dat"
    export UNIPEPT_GO_TERM_URL="file://${sources}/go-basic.obo"
    export UNIPEPT_INTERPRO_URL="file://${sources}/entry.list"
    export UNIPEPT_REFERENCE_PROTEOME_URL="file://${sources}/reference_proteomes.tsv"
}
