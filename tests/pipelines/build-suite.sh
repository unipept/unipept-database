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
SOURCES="${HERE}/sources"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

sed --version > /dev/null 2>&1 || { echo "the build suite needs GNU sed first on PATH" >&2; exit 1; }
checkdep gawk
checkdep zip
checkdep unzip

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

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


summary
