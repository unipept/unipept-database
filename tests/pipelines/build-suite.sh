#!/usr/bin/env bash
#
# Runs pipelines/suffix-array/build.sh end to end, offline: the UNIPEPT_*_URL variables point every
# source at the corpus in crates/fixtures/data and the files in tests/pipelines/sources.
#
# The files in sources/ carry the records each parser has to skip or fold: a header block, a
# record without an ID, a [Typedef], and two proteomes sharing their proteins.
#
# Needs cargo, GNU sed and coreutils, gawk, lz4, pigz, pv, xmllint, zip and unzip.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
FIXTURES="${REPO}/crates/fixtures/data"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

sed --version > /dev/null 2>&1 || { echo "the build suite needs GNU sed first on PATH" >&2; exit 1; }
checkdep gawk
checkdep zip
checkdep unzip

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

use_fixture_sources "$WORK" || exit 1

"${REPO}/pipelines/suffix-array/build.sh" --database-sources swissprot \
    --output-dir "${WORK}/output" --temp-dir "${WORK}/temp" > "${WORK}/build.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || tail -n 20 "${WORK}/build.log" >&2

table() { lz4 -dc "${WORK}/output/$1.tsv.lz4" 2> /dev/null; }

# The rows without the running id, sorted: the threaded parser writes them in the order it finishes.
rows_without_id() { cut -f 2- | LC_ALL=C sort; }


section "the build"
check_true "the build succeeds" [ "$rc" -eq 0 ]
check "the UniProt version" "$(cat "${WORK}/output/.version" 2> /dev/null)" "2026.09"


section "the tables made from the corpus"
# cmp, not check: the fifth column of taxons.tsv is a raw 0x01 or 0x00 byte.
check_true "taxons.tsv is the fixture" cmp -s <(table taxons) "${FIXTURES}/taxons.tsv"
check_true "lineages.tsv is the fixture" cmp -s <(table lineages) "${FIXTURES}/lineages.tsv"
check "uniprot_entries.tsv has the fixture rows" \
    "$(table uniprot_entries | rows_without_id)" "$(rows_without_id < "${FIXTURES}/uniprot_entries.tsv")"


section "the tables made from the sources"
check "ec_numbers.tsv" "$(table ec_numbers)" "$(printf '%s\n' \
    $'1\t1.-.-.-\tOxidoreductases' \
    $'2\t1.1.1.1\tAlcohol dehydrogenase' \
    $'3\t1.1.1.2\tAlcohol dehydrogenase (NADP(+))' \
    $'4\t1.14.11.1\t2-oxoglutarate 3-dioxygenase' \
    $'5\t2.7.11.1\tNon-specific serine/threonine protein kinase')"
check "go_terms.tsv" "$(table go_terms)" "$(printf '%s\n' \
    $'1\tGO:0009279\tcellular component\tcell outer membrane' \
    $'2\tGO:0005515\tmolecular function\tprotein binding')"
check "interpro_entries.tsv" "$(table interpro_entries)" "$(printf '%s\n' \
    $'1\tIPR016364\tFamily\tAlcohol dehydrogenase, zinc-type' \
    $'2\tIPR008816\tDomain\tPeptidase inhibitor I36')"
check "proteomes.tsv" "$(table proteomes)" "$(printf '%s\n' \
    $'1\tUP000000001\t8501\t3\tP00001;P00002;P00010' \
    $'2\tUP000000002\t8502\t2\tP00003;P00011' \
    $'3\tUP000000003\t7\t1\tP00006' \
    $'4\tUP000000004\t8502\t2\tP00003;P00011')"


section "the suffix array, with a stand-in sa-builder"
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/sa-builder" <<SA
#!/usr/bin/env bash
prev=''
for arg in "\$@"; do
    case "\$prev" in
        --database-file) cp "\$arg" "${WORK}/proteins-given.tsv" ;;
        --output-sa | --output-proteins | --output-mapping | --output-kmer-table)
            printf 'binary\n' > "\$arg" ;;
    esac
    prev="\$arg"
done
printf '%s\n' "\$*" > "${WORK}/sa-builder-call"
exit "\${SA_BUILDER_STATUS:-0}"
SA
chmod +x "${WORK}/bin/sa-builder"

build_index() {
    PATH="${WORK}/bin:${PATH}" "${REPO}/pipelines/suffix-array/build-index.sh" "$@" > "${WORK}/index.log" 2>&1
}

entries="${WORK}/output/uniprot_entries.tsv.lz4"
build_index --uniprot-entries "$entries" --output-dir "${WORK}/index"
check "the build succeeds" "$?" "0"
for file in sa.bin proteins.bin mapping.bin kmer_table.bin; do
    check_true "it writes ${file}" test -s "${WORK}/index/${file}"
done
check "sa-builder is given accession, taxon, sequence and annotations" \
    "$(LC_ALL=C sort "${WORK}/proteins-given.tsv")" \
    "$(cut -f2,4,7,8 "${FIXTURES}/uniprot_entries.tsv" | LC_ALL=C sort)"
check_true "the k-mer size is 5" grep -qF -- '--kmer-size 5 ' "${WORK}/sa-builder-call"
check_true "the sparseness factor is 2" grep -qF -- '--sparseness-factor 2 ' "${WORK}/sa-builder-call"
check_true "the algorithm is lib-sais" grep -qF -- '--construction-algorithm lib-sais ' "${WORK}/sa-builder-call"
check_true "the suffix array is compressed" grep -qF -- '--compress-sa' "${WORK}/sa-builder-call"
check_true "the protein file is removed" test ! -e "${WORK}/index/proteins.tsv"

SA_BUILDER_STATUS=3 build_index --uniprot-entries "$entries" --output-dir "${WORK}/failed"
check "a failed sa-builder fails the build" "$?" "3"
check_true "and the protein file is removed" test ! -e "${WORK}/failed/proteins.tsv"

build_index --uniprot-entries "${WORK}/missing.tsv.lz4" --output-dir "${WORK}/refused"
check "a missing table is refused" "$?" "1"
check_true "before anything is written" test ! -e "${WORK}/refused"


summary
