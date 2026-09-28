#!/usr/bin/env bash
#
# Builds a Unipept database on this host: the tables, the suffix array and the datastore layout the
# API reads. It loads nothing into OpenSearch; .deploy/load.sh does that. Run it with --help for the
# options.

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

# Whether to build without first checking there is memory for the suffix array.
SKIP_MEMORY_CHECK=false

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
Builds a Unipept database on this host: the tables, the suffix array and the datastore layout the
API reads. .deploy/load.sh then loads its proteins into OpenSearch.

  .deploy/build.sh [OPTIONS]

  --output-dir DIR         where the finished databases are written
  --scratch-dir DIR        where the repositories are cloned and built
  --database-sources LIST  swissprot, trembl, or both, comma separated
  --replace                replace a database of the version this build turns out to be
  --skip-memory-check      build without first checking there is memory for the suffix array
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
            --replace) REPLACE=true; shift ;;
            --skip-memory-check) SKIP_MEMORY_CHECK=true; shift ;;
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

    local peak_file="${build_dir}/sa-builder-peak"
    SA_INPUT_BYTES=$(stat -c %s "${build_dir}/suffix-array/proteins.tsv")
    check_memory_for "$SA_INPUT_BYTES"

    # Under GNU time, for the peak it reached: what the next build on this host checks against.
    log "Started building the suffix array."
    /usr/bin/time -f '%M' -o "$peak_file" "${index_dir}/target/release/sa-builder" \
        --database-file "${build_dir}/suffix-array/proteins.tsv" \
        --output-sa "${build_dir}/suffix-array/sa.bin" \
        --output-proteins "${build_dir}/suffix-array/proteins.bin" \
        --output-mapping "${build_dir}/suffix-array/mapping.bin" \
        --output-kmer-table "${build_dir}/suffix-array/kmer_table.bin" \
        --kmer-size "$SA_KMER_SIZE" \
        --sparseness-factor "$SA_SPARSENESS" \
        --construction-algorithm "$SA_ALGORITHM" \
        --compress-sa
    SA_PEAK_KIB=$(tail -n 1 "$peak_file")
    rm -f "$peak_file"
    log "Finished building the suffix array, at a peak of $(( SA_PEAK_KIB / 1024 / 1024 )) GiB."

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

# A value build-info.txt holds as "key: value".
value_in() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    sed -n "s/^${key}: *//p" "$file" | tail -n 1
}

# The memory the kernel can hand out without swapping, in KiB.
memory_available_kib() {
    awk '/^MemAvailable:/ { print $2 }' /proc/meminfo
}

# What an earlier build on this host recorded of sa-builder, as "input_bytes peak_kib", from the
# newest database that has it. Nothing when none has.
recorded_peak() {
    local candidate input peak found=''

    # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
    for candidate in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
        input=$(value_in "${candidate}/suffix-array/build-info.txt" 'sa-builder input bytes')
        peak=$(value_in "${candidate}/suffix-array/build-info.txt" 'sa-builder peak KiB')
        [ -n "$input" ] && [ -n "$peak" ] && found="${input} ${peak}"
    done
    printf '%s\n' "$found"
}

opensearch_running() {
    command -v systemctl > /dev/null && systemctl is-active --quiet opensearch 2> /dev/null
}

# What is holding memory on this host, for the operator to act on: the two services that share a
# build host, and the largest processes.
memory_holders() {
    local api_pid
    api_pid=$(pgrep -x unipept-api | head -n 1) || true
    [ -z "$api_pid" ] || echo "  the Unipept API is running (pid ${api_pid}, $(( $(ps -o rss= -p "$api_pid") / 1024 / 1024 )) GiB)."
    ! opensearch_running || echo "  OpenSearch is running."
    echo "  The largest processes, in GiB:"
    ps -eo rss=,comm= --sort=-rss | head -n 5 | awk '{ printf "    %6.1f  %s\n", $1 / 1024 / 1024, $2 }'
}

# What to do about it, the same in every message.
readonly FREE_MEMORY="Take this host out of the pool, stop the API (systemctl --user stop unipept-api) and OpenSearch (sudo systemctl stop opensearch), and build again. --skip-memory-check builds anyway."

# Stops, before the pipeline, a build that the suffix array will not fit. With an earlier build's
# peak, by that peak. Without one, by whether the API or OpenSearch is running: on a build host they
# hold the memory sa-builder needs, and a build with them running was killed hours in.
check_memory_at_start() {
    [ "$SKIP_MEMORY_CHECK" != true ] || return 0
    local recorded peak available
    recorded=$(recorded_peak)
    available=$(memory_available_kib)

    if [ -n "$recorded" ]; then
        peak=${recorded#* }
        # A release is somewhat larger than the one before.
        [ "$(( peak * 11 / 10 ))" -le "$available" ] && return 0
        die "the suffix array took $(( peak / 1024 / 1024 )) GiB in the last build here, and $(( available / 1024 / 1024 )) GiB is available.
$(memory_holders)
${FREE_MEMORY}"
    fi

    if pgrep -x unipept-api > /dev/null || opensearch_running; then
        die "no earlier build here recorded what the suffix array needs, and something that holds the memory it needs is running.
$(memory_holders)
${FREE_MEMORY}"
    fi
}

# Stops before sa-builder starts, now that its input is known, where an earlier build's peak says
# it will not fit: stopped here, rather than killed by the kernel part way through it.
check_memory_for() {
    [ "$SKIP_MEMORY_CHECK" != true ] || return 0
    local input_bytes="$1" recorded needed available
    recorded=$(recorded_peak)
    [ -n "$recorded" ] || { log "No earlier build here recorded what the suffix array needs; this one records it."; return 0; }

    # Scaled by how much larger the input is than last time.
    needed=$(awk -v peak="${recorded#* }" -v was="${recorded% *}" -v now="$input_bytes" \
        'BEGIN { printf "%d", peak / was * now * 1.05 }')
    available=$(memory_available_kib)
    [ "$needed" -le "$available" ] && return 0

    die "the suffix array needs about $(( needed / 1024 / 1024 )) GiB for this input, going by the last build here, and $(( available / 1024 / 1024 )) GiB is available.
$(memory_holders)
${FREE_MEMORY}"
}

parse_arguments "$@"
refuse_root

[ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value."
[ -n "$SCRATCH_DIR" ] || die "--scratch-dir requires a value."

# What this script runs itself. The pipeline checks its own tools in the seconds after it starts,
# so they are not repeated here.
checkdep git
checkdep cargo "the Rust toolchain"
checkdep cmake
checkdep pgrep procps
# GNU time, for what sa-builder takes. Not `command -v time`, which finds the shell's keyword.
[ -x /usr/bin/time ] || die "GNU time is not installed at /usr/bin/time; .deploy/opensearch/install.sh installs it, as the time package."

# The checkout this script belongs to is what builds the database, so it is what build-info.txt
# records. A deploy from an archive rather than a clone has no commit to name.
DATABASE_COMMIT=$(git -C "${HERE}/.." rev-parse HEAD 2>/dev/null || echo unknown)

# The build writes here and is renamed into place at the end. Beside the finished databases, so the
# rename stays within one filesystem, and because the version it will be named after is not known
# until the pipeline has run.
STAGING_DIR="${OUTPUT_DIR}/.build"
rm -rf "${STAGING_DIR:?}"
mkdir -p "${STAGING_DIR}"/{suffix-array,tables,temp}

check_memory_at_start

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

# Last, so a directory that carries this file is a finished build.
write_build_info "${STAGING_DIR}/suffix-array" "$UNIPROT_VERSION" "$DATABASE_COMMIT" "$INDEX_COMMIT"
printf 'sa-builder input bytes: %s\nsa-builder peak KiB: %s\n' "$SA_INPUT_BYTES" "$SA_PEAK_KIB" \
    >> "${STAGING_DIR}/suffix-array/build-info.txt"

swap_into_place "$STAGING_DIR" "$BUILD_DIR"

log "The database is ready in ${BUILD_DIR}. Load its proteins with: .deploy/load.sh --uniprot-version ${UNIPROT_VERSION}"
