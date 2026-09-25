# shellcheck shell=bash
#
# The assertions and the setup the suites share. Sourced, never run.

TESTS_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"

# checkdep and the other helpers the pipelines use. Here rather than in each suite, so a suite's
# dependency checks exist whether or not it remembers to source them.
# shellcheck source=../pipelines/lib/common.sh
source "${TESTS_DIR}/../pipelines/lib/common.sh"

pass=0
fail=0

# The case being run. A failure prints it, because the assertion name alone is read out of a log
# where the heading above it is far up the output.
current_section=''
# Every failure, collected so the summary can repeat them.
failures=''

# Compares what happened with what should have happened, and keeps going either way: a suite
# reports everything that is wrong in one run rather than stopping at the first.
check() {
    local what=$1 got=$2 want=$3

    if [ "$got" = "$want" ]; then
        printf '  PASS %s\n' "$what"
        pass=$((pass + 1))
    else
        printf '  FAIL [%s] %s: expected [%s] got [%s]\n' "${current_section:-no section}" "$what" "$want" "$got"
        failures="${failures}  [${current_section:-no section}] ${what}: expected [${want}] got [${got}]"$'\n'
        fail=$((fail + 1))
    fi
}

# For a condition that is true or not, rather than a value to compare.
check_true() {
    local what=$1
    shift
    if "$@"; then check "$what" yes yes; else check "$what" no yes; fi
}

# Names the case that follows, and is what a failure inside it reports. Every case goes through
# here: a heading printed with `echo` records nothing, so its failures would name no case.
section() {
    current_section="$*"
    printf '== %s ==\n' "$*"
}

# The last thing a suite runs. Non-zero if anything failed, so the runner can stop.
summary() {
    if [ "$fail" -gt 0 ]; then
        printf '\nwhat failed:\n%s' "$failures"
    fi
    printf '\npassed=%s failed=%s\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]
}

# A heading between suites, or between the steps of one.
heading() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# For the suites that start containers.
require_docker() {
    command -v docker > /dev/null || { echo "docker is not installed" >&2; exit 1; }
    docker info > /dev/null 2>&1 || { echo "the Docker daemon is not running" >&2; exit 1; }
}

# Commits everything in a repository a suite made, under a throwaway identity.
commit_all() {
    local repo="$1" message="$2"

    git -C "$repo" add -A
    git -C "$repo" -c user.email=t@example.com -c user.name=t commit -qm "$message"
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
