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

# The scripts in .deploy as a checkout lays them out, in DEST, which has to exist: the scripts, the
# parts of lib.sh, and the OpenSearch helpers lib.sh loads from beside .deploy. What a checkout needs
# beyond that, such as the pipelines build.sh runs, is the caller's to add.
copy_deploy_scripts() {
    local repo="$1" dest="$2"

    mkdir -p "${dest}/.deploy/opensearch" "${dest}/opensearch"
    cp "${repo}"/.deploy/*.sh "${repo}/.deploy/deploy.conf.example" "${dest}/.deploy/"
    cp -R "${repo}/.deploy/lib" "${dest}/.deploy/"
    cp "${repo}"/.deploy/opensearch/*.sh "${dest}/.deploy/opensearch/"
    cp "${repo}/opensearch/lib.sh" "${dest}/opensearch/"
}

# A whole database of a version, in ROOT/uniprot-VERSION, made afresh: every file the API needs with
# content, its .version, build-info.txt and the table load.sh reads. Prints its suffix-array, the
# directory the API is pointed at.
make_database() {
    local root=$1 version=$2 relative
    local index="${root}/uniprot-${version}/suffix-array"

    chmod -R u+rwx "$root" 2> /dev/null
    rm -rf "${root:?}"
    # The lists from a bash of its own: a suite that has sourced database.sh holds them read-only.
    # shellcheck disable=SC2016 # expanded by that bash
    while read -r relative; do
        mkdir -p "$(dirname "${index}/${relative}")"
        printf 'content\n' > "${index}/${relative}"
    done < <(bash -c 'source "$1"; printf "%s\n" "${INDEX_FILES[@]}" "${OPTIONAL_INDEX_FILES[@]}"' _ \
        "${TESTS_DIR}/../.deploy/lib/database.sh")
    printf '%s\n' "${version//-/.}" > "${index}/.version"
    printf 'uniprot: %s\n' "$version" > "${index}/build-info.txt"
    mkdir -p "${root}/uniprot-${version}/tables"
    printf 'rows\n' > "${root}/uniprot-${version}/tables/uniprot_entries.tsv.lz4"
    echo "$index"
}

# A stand-in command: a shell script at PATH that runs BODY. Prints PATH.
make_stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$1"
    chmod +x "$1"
    echo "$1"
}

# A stand-in for the API's deploy.sh, at a path: `status` prints the lines in PATH.status, which a
# case writes with api_status_lines, and every other command is appended to PATH.log and succeeds.
# Prints the path.
make_api_deploy() {
    make_stub "$1" "if [ \"\$1\" = status ]; then cat '${1}.status'; else echo \"\$*\" >> '${1}.log'; fi"
}

# What the API's deploy.sh status prints, in the format these scripts read, for an API whose
# INDEX_LOCATION and OpenSearch index are the ones given, `-` for none, as for files without a
# .version, with its lock where it is given. The version of the index, as the real one reports it.
api_status_lines() {
    local version='-'
    [ "$2" = - ] || { version=${2#uniprot_entries-}; version=${version/-/.}; }
    printf 'status_format=1\nversion=2.7.0\nprevious=-\nvariant=hybrid\nport=8080\nactive=active\n'
    printf 'index_location=%s\nindex_version=%s\nopensearch_index=%s\napi_lock=%s\n' "$1" "$version" "$2" "${3:-/run/lock/unipept-api.lock}"
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
