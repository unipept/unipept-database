#!/usr/bin/env bash
#
# Builds a Unipept database on this host: the tables, the suffix array, the datastore layout the
# API reads, and the proteins in OpenSearch. Run it with --help for the options.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

# The settings only this script has. lib.sh holds the ones it shares.

# Where the repositories are cloned and built. The tables are not built here: they go to a staging
# directory under OUTPUT_DIR, which is the volume that has to hold the whole build.
SCRATCH_DIR="$HOME"

DATABASE_SOURCES=swissprot,trembl

INDEX_REPO=https://github.com/unipept/unipept-index.git

# Whether a database of the version this build turns out to be may be replaced. Off, a build whose
# version already exists stops and keeps its own result, rather than removing what the API serves.
REPLACE=false

read_conf

# sa-builder settings, below read_conf because they are not a host's to change: an index built with
# other values still looks valid to the API, so a mistake here is only visible in what it serves.
SA_SPARSENESS=2
SA_ALGORITHM=lib-sais

# The k-mer table is an accelerator the API loads when it is there. Without it every search reads
# the whole suffix array. It is a dense bucket array, about 127 MB at k=5 whatever the database
# size.
SA_KMER_SIZE=5

usage() {
    cat <<'USAGE'
Builds a Unipept database on this host: the tables, the suffix array, the datastore layout the API
reads, and the proteins in OpenSearch.

  .deploy/build.sh [OPTIONS]

  --output-dir DIR         where the finished databases are written
  --scratch-dir DIR        where the repositories are cloned and built
  --database-sources LIST  swissprot, trembl, or both, comma separated
  --opensearch-url URL     the instance the proteins are loaded into
  --replace                replace a database of the version this build turns out to be
  --help                   print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib.sh and in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --scratch-dir) need_value "$1" "${2-}"; SCRATCH_DIR="$2"; shift 2 ;;
            --database-sources) need_value "$1" "${2-}"; DATABASE_SOURCES="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --replace) REPLACE=true; shift ;;
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

# The proteins, in the OpenSearch instance the API queries.
load_opensearch() {
    local build_dir="$1"

    log "Started loading the proteins into OpenSearch."
    "${HERE}/../opensearch/load.sh" \
        --opensearch-url "$OPENSEARCH_URL" \
        --uniprot-entries "${build_dir}/tables/uniprot_entries.tsv.lz4"
    log "Finished loading the proteins into OpenSearch."
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
[ -n "$SCRATCH_DIR" ] || die "--scratch-dir requires a value."

# What this script runs itself. The pipeline checks its own tools in the seconds after it starts,
# so they are not repeated here; the loader's are, because it runs last.
checkdep git
checkdep cargo "the Rust toolchain"
checkdep cmake
check_loader_deps

# The checkout this script belongs to is what builds the database, so it is what build-info.txt
# records. A deploy from an archive rather than a clone has no commit to name.
DATABASE_COMMIT=$(git -C "${HERE}/.." rev-parse HEAD 2>/dev/null || echo unknown)

# The build writes here and is renamed into place at the end. Beside the finished databases, so the
# rename stays within one filesystem, and because the version it will be named after is not known
# until the pipeline has run.
STAGING_DIR="${OUTPUT_DIR}/.build"
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

# As soon as the layout is complete, and before anything outside the staging directory changes: the
# load below drops and recreates the index the API queries, so a build refused after it would
# already have replaced the proteins that serve the database it leaves in place.
verify_database "${STAGING_DIR}/suffix-array" || die "the build is missing files the API needs."

UNIPROT_VERSION=$(uniprot_version_from "${STAGING_DIR}/tables/.version")
log "UniProtKB version is ${UNIPROT_VERSION}."

BUILD_DIR="${OUTPUT_DIR}/uniprot-${UNIPROT_VERSION}"
if [ -e "$BUILD_DIR" ] && [ "$REPLACE" != true ]; then
    die "${BUILD_DIR} already exists. This build is in ${STAGING_DIR}; pass --replace to replace it."
fi

load_opensearch "$STAGING_DIR"

# After the load, so a directory that carries this file is one whose proteins are in OpenSearch.
write_build_info "${STAGING_DIR}/suffix-array" "$UNIPROT_VERSION" "$DATABASE_COMMIT" "$INDEX_COMMIT"

swap_into_place "$STAGING_DIR" "$BUILD_DIR"

log "The database is ready in ${BUILD_DIR}."
