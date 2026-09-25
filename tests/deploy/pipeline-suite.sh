#!/usr/bin/env bash
#
# .deploy/build.sh over the real pipeline: the seam tests/deploy/cases.sh stubs.
#
# That suite replaces the pipeline with a stand-in, so it proves build.sh's own logic and nothing
# about the contract between the two — the flags it passes, the table names it expects, the format
# of the .version it reads. A stand-in written from reading the script agrees with the script by
# construction. This runs the real pipeline, offline, against the fixtures
# tests/pipelines/build-suite.sh uses.
#
# sa-builder and the OpenSearch loader stay stand-ins: each has a suite of its own, and building a
# real index is unipept-index's work and hours of it.
#
# Needs cargo, GNU sed and coreutils, gawk, lz4, pigz, pv, uuidgen, xmllint, zip and unzip, and
# python3 with requests, which build.sh checks for the loader before it starts.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
FIXTURES="${REPO}/crates/fixtures/data"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"

sed --version > /dev/null 2>&1 || { echo "this suite needs GNU sed first on PATH" >&2; exit 1; }
checkdep cargo
checkdep gawk
checkdep lz4
checkdep pigz
checkdep pv
checkdep uuidgen
checkdep xmllint
checkdep zip
checkdep unzip

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

readonly TREE="${WORK}/tree"
readonly INDEX_REPO="${WORK}/unipept-index"
readonly OUT="${WORK}/data"

# A tree .deploy/build.sh can run in: the real pipeline, crates and assets, and a stand-in loader
# where the real one would be. cargo resolves the manifest to the repository, so the build reuses
# whatever is already compiled there.
setup_tree() {
    mkdir -p "${TREE}/opensearch" "${REPO}/target"
    cp -R "${REPO}/.deploy" "${TREE}/.deploy"

    local path
    for path in Cargo.toml Cargo.lock rust-toolchain.toml crates pipelines assets target; do
        ln -s "${REPO}/${path}" "${TREE}/${path}"
    done

    make_loader "${TREE}/opensearch/load.sh" "${WORK}/loader-calls"

    printf 'INDEX_REPO=%s\n' "$INDEX_REPO" > "${TREE}/.deploy/deploy.conf"
}

setup_tree
make_index_repo "$INDEX_REPO" "$WORK"

# Every source the pipeline downloads, pointed at the corpus, as tests/pipelines/build-suite.sh
# does.
use_fixture_sources "$WORK" || exit 1

mkdir -p "$OUT"
"${TREE}/.deploy/build.sh" \
    --output-dir "$OUT" \
    --scratch-dir "${WORK}/scratch" \
    --database-sources swissprot > "${WORK}/build.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || tail -n 25 "${WORK}/build.log" >&2

# The fixture RELEASE.metalink says 2026_09, which the pipeline writes as 2026.09.
readonly INDEX_DIR="${OUT}/uniprot-2026-09/suffix-array"


section "the build"

check "it succeeds" "$rc" "0"
check_true "the database is named from the version the pipeline wrote" test -d "${OUT}/uniprot-2026-09"
check "the .version beside the index agrees with the name" \
    "$(cat "${INDEX_DIR}/.version" 2> /dev/null)" "2026.09"
check_true "verify.sh passes on what the real pipeline produced" \
    "${TREE}/.deploy/verify.sh" --index-dir "$INDEX_DIR"
check_true "the staging directory is gone" test ! -d "${OUT}/.build"


section "the tables the pipeline actually writes"

# build.sh names these in PIPELINE_TABLES and DATASTORE_TABLES. If the pipeline renamed one, the
# build would have stopped above; these say which side of the seam the names came from.
for table in taxons lineages interpro_entries go_terms ec_numbers proteomes; do
    check_true "datastore/${table}.tsv has rows" test -s "${INDEX_DIR}/datastore/${table}.tsv"
done
check_true "taxons.tsv is the fixture table" \
    cmp -s "${INDEX_DIR}/datastore/taxons.tsv" "${FIXTURES}/taxons.tsv"
check_true "the entries table is kept for clone.sh" \
    test -s "${OUT}/uniprot-2026-09/tables/uniprot_entries.tsv.lz4"


section "the columns handed to sa-builder"

# build.sh cuts fields 2,4,7,8 out of uniprot_entries.tsv. The column layout is a contract three
# consumers slice by position, and this is the one that no parser test covers.
given="${WORK}/proteins-given-to-sa-builder.tsv"
entries="$(lz4 -dc "${OUT}/uniprot-2026-09/tables/uniprot_entries.tsv.lz4" | wc -l | tr -d ' ')"

check_true "sa-builder was given a protein file" test -s "$given"
check "it has one row per entry" "$(wc -l < "$given" | tr -d ' ')" "$entries"
check "every row has four columns" \
    "$(gawk -F'\t' '{print NF}' "$given" | sort -u | tr '\n' ' ')" "4 "
check "the accession column holds accessions" \
    "$(gawk -F'\t' 'NR == 1 { print ($1 ~ /^[A-Z][0-9][A-Z0-9]{3}[0-9]$/) ? "yes" : "no" }' "$given")" "yes"
check "the sequence column holds residues" \
    "$(gawk -F'\t' 'NR == 1 { print ($3 ~ /^[A-Z]+$/) ? "yes" : "no" }' "$given")" "yes"
check "the taxon column holds a number" \
    "$(gawk -F'\t' 'NR == 1 { print ($2 ~ /^[0-9]+$/) ? "yes" : "no" }' "$given")" "yes"


section "the loader"

check "it was called once" "$(grep -c -- '--uniprot-entries' "${WORK}/loader-calls" 2> /dev/null)" "1"

# The proteins are loaded before the build is renamed into place, so the path it was given is the
# staging one. A database only appears where the API reads it once the load has succeeded.
loaded="$(gawk '{ for (i = 1; i < NF; i++) if ($i == "--uniprot-entries") print $(i + 1) }' \
    "${WORK}/loader-calls")"
check "it was given the entries table of the build" \
    "$(basename "$loaded")" "uniprot_entries.tsv.lz4"
check "from the staging directory, before the swap" \
    "$(case "$loaded" in "${OUT}/.build/"*) echo yes ;; *) echo no ;; esac)" "yes"


summary
