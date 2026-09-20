#!/usr/bin/env bash
#
# Builds a Unipept database on this host: the tables, the suffix array, the datastore layout the
# API reads, and the proteins in OpenSearch.
#
#   .deploy/build.sh [--output-dir DIR] [--database-sources LIST] [--opensearch-url URL]
#
# Settings come from the environment, then .deploy/build.conf, then the defaults in lib.sh.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR

# sa-builder settings. Not configurable: the release build in unipept-index uses the same ones, and
# an index built with other values still looks valid to the API.
SA_SPARSENESS=2
SA_ALGORITHM=lib-sais

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --database-sources) DATABASE_SOURCES="$2"; shift 2 ;;
            --opensearch-url) OPENSEARCH_URL="$2"; shift 2 ;;
            --help) sed -n '2,8p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done
}

# The tables, built from the pipeline in a fresh clone of unipept-database.
generate_tables() {
    local build_dir="$1"

    DATABASE_COMMIT=$(clone_repo "$DATABASE_REPO" "${SCRATCH_DIR:?}/unipept-database")
    log "Cloned unipept-database at ${DATABASE_COMMIT}."

    "${SCRATCH_DIR:?}/unipept-database/pipelines/suffix-array/build.sh" \
        --database-sources "$DATABASE_SOURCES" \
        --output-dir "${build_dir}/tables" \
        --temp-dir "${build_dir}/temp"

    local table
    for table in uniprot_entries taxons lineages interpro_entries go_terms ec_numbers proteomes; do
        [ -s "${build_dir}/tables/${table}.tsv.lz4" ] || die "the pipeline wrote no ${table}.tsv.lz4"
    done

    log "Finished building the tables."
}

# The suffix array the API searches, built from a fresh clone of unipept-index.
build_suffix_array() {
    local build_dir="$1"

    INDEX_COMMIT=$(clone_repo "$INDEX_REPO" "${SCRATCH_DIR:?}/unipept-index")
    log "Cloned unipept-index at ${INDEX_COMMIT}."
    cargo build --release --quiet --manifest-path "${SCRATCH_DIR:?}/unipept-index/Cargo.toml"

    # The four columns sa-builder reads: accession, taxon, sequence, annotations.
    lz4cat "${build_dir}/tables/uniprot_entries.tsv.lz4" | cut -f2,4,7,8 > "${build_dir}/suffix-array/proteins.tsv"

    log "Started building the suffix array."
    "${SCRATCH_DIR:?}/unipept-index/target/release/sa-builder" \
        --database-file "${build_dir}/suffix-array/proteins.tsv" \
        --output-sa "${build_dir}/suffix-array/sa.bin" \
        --output-proteins "${build_dir}/suffix-array/proteins.bin" \
        --output-mapping "${build_dir}/suffix-array/mapping.bin" \
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
    for table in taxons lineages interpro_entries go_terms ec_numbers proteomes; do
        lz4cat "${build_dir}/tables/${table}.tsv.lz4" > "${datastore}/${table}.tsv"
        rm "${build_dir}/tables/${table}.tsv.lz4"
    done

    cp "${SCRATCH_DIR:?}/unipept-database/assets/sampledata.json" "${datastore}/sampledata.json"
    cp "${build_dir}/tables/.version" "${build_dir}/suffix-array/.version"
    log "Filled the datastore."
}

# The proteins, in the OpenSearch instance the API queries.
load_opensearch() {
    local build_dir="$1"

    log "Started loading the proteins into OpenSearch."
    "${SCRATCH_DIR:?}/unipept-database/opensearch/load.sh" \
        --opensearch-url "$OPENSEARCH_URL" \
        --uniprot-entries "${build_dir}/tables/uniprot_entries.tsv.lz4"
    log "Finished loading the proteins into OpenSearch."
}

parse_arguments "$@"

checkdep git
checkdep curl
checkdep lz4
checkdep cargo "the Rust toolchain"
checkdep uuidgen
checkdep pv
checkdep pigz
checkdep cmake

UNIPROT_VERSION=$(latest_uniprot_version)
log "UniProtKB version is ${UNIPROT_VERSION}."

BUILD_DIR="${OUTPUT_DIR:?}/uniprot-${UNIPROT_VERSION}"
rm -rf "${BUILD_DIR:?}"
mkdir -p "${BUILD_DIR}"/{suffix-array,tables,temp}

generate_tables "$BUILD_DIR"
build_suffix_array "$BUILD_DIR"
fill_datastore "$BUILD_DIR"
write_build_info "${BUILD_DIR}/suffix-array" "$UNIPROT_VERSION" "$DATABASE_COMMIT" "$INDEX_COMMIT"
load_opensearch "$BUILD_DIR"

log "The database is ready in ${BUILD_DIR}."
