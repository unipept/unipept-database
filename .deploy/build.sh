#!/usr/bin/env bash
#
# Builds a Unipept database on this host: the tables, the suffix array and the datastore layout the
# API reads. It loads nothing into OpenSearch; .deploy/load.sh does that. Run it with --help for the
# options.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# The settings only this script has. lib/ holds the ones it shares.

# Where the repositories are cloned and built. The tables are not built here: they go to a staging
# directory under OUTPUT_DIR, which is the volume that has to hold the whole build.
SCRATCH_DIR="$HOME"

DATABASE_SOURCES=swissprot,trembl

INDEX_REPO=https://github.com/unipept/unipept-index.git

# Whether a database of the version this build turns out to be may be replaced. Off, a build whose
# version already exists stops and keeps its own result, rather than removing what the API serves.
REPLACE=false

# Whether to build without first checking the host has room for it.
SKIP_CHECKS=false

read_conf

# sa-builder settings, below read_conf because they are not a host's to change: an index built with
# other values still looks valid to the API, so a mistake here is only visible in what it serves.
SA_SPARSENESS=2
SA_ALGORITHM=lib-sais

# The k-mer table is an accelerator the API loads when it is there. Without it every search reads
# the whole suffix array. It is a dense bucket array, about 127 MB at k=5 whatever the database
# size.
SA_KMER_SIZE=5

# The UniProtKB version the pipeline wrote beside the tables, as YYYY-MM.
uniprot_version_from() {
    local version_file="$1" version

    [ -s "$version_file" ] || die "the pipeline wrote no version in ${version_file}"
    version=$(read_version "$version_file")
    [ -n "$version" ] || die "the version in ${version_file} is empty"
    echo "$version"
}

# Clones a repository at the tip of its default branch and prints the commit it got.
clone_repo() {
    local url="$1" target="$2"

    rm -rf "${target:?}"
    git clone --quiet "$url" "$target" || die "could not clone $url"
    git -C "$target" rev-parse HEAD
}

# What this build was made of, next to the index it belongs to.
write_build_info() {
    local target="$1" uniprot_version="$2" database_commit="$3" index_commit="${4:-none}"

    cat > "$target/build-info.txt" <<INFO
built: $(date -u +'%F %T UTC')
uniprot: ${uniprot_version}
unipept-database: ${database_commit}
unipept-index: ${index_commit}
sources: ${DATABASE_SOURCES:-none}
INFO
}

usage() {
    cat <<'USAGE'
Builds a Unipept database on this host: the tables, the suffix array and the datastore layout the
API reads. .deploy/load.sh then loads its proteins into OpenSearch.

  .deploy/build.sh [OPTIONS]

  --output-dir DIR         where the finished databases are written
  --scratch-dir DIR        where the repositories are cloned and built
  --database-sources LIST  swissprot, trembl, or both, comma separated
  --replace                replace a database of the version this build turns out to be
  --skip-checks            build without first checking the host has room for it
  --help                   print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib/ and in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --scratch-dir) need_value "$1" "${2-}"; SCRATCH_DIR="$2"; shift 2 ;;
            --database-sources) need_value "$1" "${2-}"; DATABASE_SOURCES="$2"; shift 2 ;;
            --replace) REPLACE=true; shift ;;
            --skip-checks) SKIP_CHECKS=true; shift ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done
}

# The tables, built from the pipeline in this checkout.
generate_tables() {
    local build_dir="$1"

    "${HERE}/../pipelines/suffix-array/build.sh" \
        --database-sources "$DATABASE_SOURCES" \
        --output-dir "${build_dir}/tables" \
        --temp-dir "${build_dir}/temp"

    local table
    for table in "${PIPELINE_TABLES[@]}"; do
        [ -s "${build_dir}/tables/${table}.tsv.lz4" ] || die "the pipeline wrote no ${table}.tsv.lz4"
    done

    log "Finished building the tables."
}

# The suffix array the API searches, built from a fresh clone of unipept-index.
build_suffix_array() {
    local build_dir="$1" index_dir="$2"

    cargo build --release --quiet --manifest-path "${index_dir}/Cargo.toml"

    # The four columns sa-builder reads: accession, taxon, sequence, annotations.
    lz4cat "${build_dir}/tables/uniprot_entries.tsv.lz4" | cut -f2,4,7,8 > "${build_dir}/suffix-array/proteins.tsv"

    log "Started building the suffix array."
    "${index_dir}/target/release/sa-builder" \
        --database-file "${build_dir}/suffix-array/proteins.tsv" \
        --output-sa "${build_dir}/suffix-array/sa.bin" \
        --output-proteins "${build_dir}/suffix-array/proteins.bin" \
        --output-mapping "${build_dir}/suffix-array/mapping.bin" \
        --output-kmer-table "${build_dir}/suffix-array/kmer_table.bin" \
        --kmer-size "$SA_KMER_SIZE" \
        --sparseness-factor "$SA_SPARSENESS" \
        --construction-algorithm "$SA_ALGORITHM" \
        --compress-sa
    log "Finished building the suffix array."

    # Around 100 GB on full UniProt, and read by nothing after this point.
    rm -f "${build_dir}/suffix-array/proteins.tsv"
}

# The tables the API reads, uncompressed, beside the index.
fill_datastore() {
    local build_dir="$1" datastore="$1/suffix-array/datastore"

    mkdir -p "$datastore"

    local table
    for table in "${DATASTORE_TABLES[@]}"; do
        lz4cat "${build_dir}/tables/${table}.tsv.lz4" > "${datastore}/${table}.tsv"
        rm "${build_dir}/tables/${table}.tsv.lz4"
    done

    cp "${HERE}/../assets/sampledata.json" "${datastore}/sampledata.json"
    cp "${build_dir}/tables/.version" "${build_dir}/suffix-array/.version"
    log "Filled the datastore."
}

# The newest database under OUTPUT_DIR, which is what the next one is sized by. Nothing when there
# is none.
previous_database() {
    local candidate newest=''

    # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
    for candidate in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
        [ -d "$candidate" ] && newest="$candidate"
    done
    printf '%s\n' "$newest"
}

# A directory's size in KiB, as its files are long rather than as the disk packs them. Fails, with
# du's own reason, on a directory it cannot measure whole.
size_kib() {
    local line
    line=$(du -sk --apparent-size -- "$1") || return 1
    echo "${line%%[[:space:]]*}"
}

gib() {
    echo "$(( $1 / 1024 / 1024 )) GiB"
}

# Stops a build the host has no room for, before anything is removed or built. The suffix array is
# the step that needs the most memory, and a build found out hours in, on a host whose API and
# OpenSearch held it, when the kernel killed sa-builder. The previous database is the measure of
# what the next one needs: 1.5 times its size free on disk, for the new database beside the old one
# and the files the build works through, and 1.2 times its size free in memory. Every problem is
# reported, not only the first.
check_host() {
    [ "$SKIP_CHECKS" != true ] || return 0
    local problems='' previous size free available staging

    grep -qsx unipept-api /proc/[0-9]*/comm \
        && problems+=$'\n'"  The Unipept API is running, and holds memory the suffix array needs."
    command -v systemctl > /dev/null && systemctl is-active --quiet opensearch 2> /dev/null \
        && problems+=$'\n'"  OpenSearch is running, and holds memory the suffix array needs."

    previous=$(previous_database)
    if [ -n "$previous" ] && ! size=$(size_kib "$previous"); then
        echo "Warning: the size of ${previous} cannot be measured, so disk and memory are not checked." 1>&2
    elif [ -n "$previous" ]; then
        # What the last build left in the staging directory is removed before this one starts. Left
        # out when it cannot be measured, which only makes the check stricter.
        staging=0
        [ ! -d "$STAGING_DIR" ] || staging=$(size_kib "$STAGING_DIR") || staging=0
        free=$(( $(df -Pk "$OUTPUT_DIR" | awk 'NR == 2 { print $4 }') + staging ))
        [ "$free" -ge "$(( size * 3 / 2 ))" ] \
            || problems+=$'\n'"  $(gib "$free") is free on disk in ${OUTPUT_DIR}, and a build needs 1.5 times the $(gib "$size") of ${previous##*/}: $(gib $(( size * 3 / 2 )))."
        available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
        if [ -n "$available" ]; then
            [ "$available" -ge "$(( size * 6 / 5 ))" ] \
                || problems+=$'\n'"  $(gib "$available") of memory is available, and a build needs 1.2 times the $(gib "$size") of ${previous##*/}: $(gib $(( size * 6 / 5 )))."
        fi
    fi

    [ -z "$problems" ] && return 0
    die "this host has no room for a build:${problems}

Free what is named above: remove what is not needed from ${OUTPUT_DIR}, and stop the API and
OpenSearch:

  ${API_DEPLOY} stop
  sudo systemctl stop opensearch

Build again, then start them, OpenSearch first:

  sudo systemctl start opensearch
  ${API_DEPLOY} start

--skip-checks builds anyway."
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
[ -n "$SCRATCH_DIR" ] || die "--scratch-dir requires a value."

# What this script runs itself. The pipeline checks its own tools in the seconds after it starts,
# so they are not repeated here.
require git "cargo:the Rust toolchain" cmake

# The checkout this script belongs to is what builds the database, so it is what build-info.txt
# records. A deploy from an archive rather than a clone has no commit to name.
DATABASE_COMMIT=$(git -C "${HERE}/.." rev-parse HEAD 2>/dev/null || echo unknown)

# The build writes here and is renamed into place at the end. Beside the finished databases, so the
# rename stays within one filesystem, and because the version it will be named after is not known
# until the pipeline has run.
STAGING_DIR="${OUTPUT_DIR}/.build"

# Before the staging directory is removed, so a build refused here keeps what an earlier one left.
check_host
# The swap at the end is made under the lock that keeps loads and switches apart: found now, not
# hours in.
require flock:util-linux
opensearch_lock_usable \
    || die "cannot open the lock ${OPENSEARCH_LOCK} as $(id -un), which the build is swapped in under. Make it writable, or set OPENSEARCH_LOCK."

rm -rf "${STAGING_DIR:?}"
mkdir -p "${STAGING_DIR}"/{suffix-array,tables,temp}

generate_tables "$STAGING_DIR"

# Under a directory of its own, because clone_repo removes it first and SCRATCH_DIR is a place the
# operator also keeps work in.
INDEX_DIR="${SCRATCH_DIR}/unipept-build/unipept-index"
INDEX_COMMIT=$(clone_repo "$INDEX_REPO" "$INDEX_DIR")
log "Cloned unipept-index at ${INDEX_COMMIT}."

build_suffix_array "$STAGING_DIR" "$INDEX_DIR"
fill_datastore "$STAGING_DIR"

# Before anything outside the staging directory changes, so a build that is not whole never
# replaces one that is.
verify_database "${STAGING_DIR}/suffix-array" || die "the build is missing files the API needs."

UNIPROT_VERSION=$(uniprot_version_from "${STAGING_DIR}/tables/.version")
log "UniProtKB version is ${UNIPROT_VERSION}."

BUILD_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
if [ -e "$BUILD_DIR" ] && [ "$REPLACE" != true ]; then
    die "${BUILD_DIR} already exists. This build is in ${STAGING_DIR}; pass --replace to replace it."
fi
# Under the lock a switch holds, and the version's own that a load holds, so neither can start between
# the check that the version is not served and the swap. Waited for, since the build is hours in.
take_opensearch_lock -s "$LOCK_WAIT" \
    || die "$(lock_refused $?) Waited ${LOCK_WAIT} seconds for it. This build is in ${STAGING_DIR}."
take_load_lock "$UNIPROT_VERSION" \
    || die "a load of ${UNIPROT_VERSION} is running on this host, and reads the files this would replace. This build is in ${STAGING_DIR}; build again once it has finished."
[ ! -e "$BUILD_DIR" ] || refuse_replacing_served "$UNIPROT_VERSION" "This build is in ${STAGING_DIR}. "

# Last, so a directory that carries this file is a finished build.
write_build_info "${STAGING_DIR}/suffix-array" "$UNIPROT_VERSION" "$DATABASE_COMMIT" "$INDEX_COMMIT"

swap_into_place "$STAGING_DIR" "$BUILD_DIR"

log "The database is ready in ${BUILD_DIR}. Load its proteins with: .deploy/load.sh --uniprot-version ${UNIPROT_VERSION}"
