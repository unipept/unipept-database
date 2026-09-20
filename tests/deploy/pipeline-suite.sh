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
# Needs cargo, GNU sed and coreutils, gawk, lz4, pigz, pv, xmllint, zip and unzip.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
FIXTURES="${REPO}/crates/fixtures/data"
SOURCES="${REPO}/tests/pipelines/sources"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

# checkdep lives here, not in tests/lib.sh.
# shellcheck source=../../pipelines/lib/common.sh
source "${REPO}/pipelines/lib/common.sh"

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

    cat > "${TREE}/opensearch/load.sh" <<LOADER
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "\$*" >> "${WORK}/loader-calls"
LOADER
    chmod +x "${TREE}/opensearch/load.sh"

    printf 'INDEX_REPO=%s\n' "$INDEX_REPO" > "${TREE}/.deploy/deploy.conf"
}

# What build.sh clones for sa-builder. The stand-in keeps the file it was handed, so the suite can
# look at the columns build.sh cut out of the real uniprot_entries table.
setup_index_repo() {
    mkdir -p "${INDEX_REPO}/target/release" "${INDEX_REPO}/src"

    # A crate cargo can really build, because build.sh runs the real cargo on it before it reaches
    # sa-builder. The binary below is committed beside it and is what actually runs.
    printf '[package]\nname = "stand-in"\nversion = "0.0.0"\nedition = "2021"\n' \
        > "${INDEX_REPO}/Cargo.toml"
    printf 'fn main() {}\n' > "${INDEX_REPO}/src/main.rs"

    cat > "${INDEX_REPO}/target/release/sa-builder" <<SA
#!/usr/bin/env bash
set -eo pipefail
prev=''
for arg in "\$@"; do
    case "\$prev" in
        --database-file) cp "\$arg" "${WORK}/proteins-given-to-sa-builder.tsv" ;;
        --output-sa | --output-proteins | --output-mapping | --output-kmer-table)
            printf 'binary\n' > "\$arg" ;;
    esac
    prev="\$arg"
done
printf '%s\n' "\$*" >> "${WORK}/sa-builder-calls"
SA
    chmod +x "${INDEX_REPO}/target/release/sa-builder"

    git -C "$INDEX_REPO" init -q
    git -C "$INDEX_REPO" add -A
    git -C "$INDEX_REPO" -c user.email=t@example.com -c user.name=t commit -qm "stand-in index"
}

setup_tree
setup_index_repo

# Every source the pipeline downloads, pointed at the corpus. The same set
# tests/pipelines/build-suite.sh uses.
gzip -c "${FIXTURES}/uniprot_sprot.dat" > "${WORK}/uniprot_sprot.dat.gz" || exit 1
(cd "${FIXTURES}" && zip -q "${WORK}/taxdmp.zip" names.dmp nodes.dmp) || exit 1

export UNIPEPT_SWISSPROT_URL="file://${WORK}/uniprot_sprot.dat.gz"
export UNIPEPT_TAXDMP_URL="file://${WORK}/taxdmp.zip"
export UNIPEPT_RELEASE_METALINK_URL="file://${SOURCES}/RELEASE.metalink"
export UNIPEPT_EC_CLASS_URL="file://${SOURCES}/enzclass.txt"
export UNIPEPT_EC_NUMBER_URL="file://${SOURCES}/enzyme.dat"
export UNIPEPT_GO_TERM_URL="file://${SOURCES}/go-basic.obo"
export UNIPEPT_INTERPRO_URL="file://${SOURCES}/entry.list"
export UNIPEPT_REFERENCE_PROTEOME_URL="file://${SOURCES}/reference_proteomes.tsv"

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
