#!/usr/bin/env bash
#
# Runs pipelines/umgap/build.sh end to end in both modes, offline: the UNIPEPT_*_URL variables point
# every source at the corpus in crates/fixtures/data and the files in tests/pipelines/sources. Then
# looks up k-mers and peptides in the indexes it built.
#
# Needs cargo, umgap, GNU sed and coreutils, gawk, lz4, pigz, pv, zip and unzip.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
FIXTURES="${REPO}/crates/fixtures/data"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

sed --version > /dev/null 2>&1 || { echo "the umgap suite needs GNU sed first on PATH" >&2; exit 1; }
checkdep gawk
checkdep umgap
checkdep zip
checkdep unzip

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

use_fixture_sources "$WORK" || exit 1

# From WORK, because build.sh makes its FIFOs in the current directory.
build() {
    local mode="$1"

    (cd "$WORK" && "${REPO}/pipelines/umgap/build.sh" "$mode" --database-sources swissprot \
        --output-dir "${WORK}/${mode}" --temp-dir "${WORK}/temp-${mode}") > "${WORK}/${mode}.log" 2>&1
    local rc=$?
    [ "$rc" -eq 0 ] || tail -n 20 "${WORK}/${mode}.log" >&2
    return "$rc"
}

table() { lz4 -dc "${WORK}/$1/$2.tsv.lz4" 2> /dev/null; }

# The rows without the running id, sorted: the threaded parser writes them in the order it finishes.
rows_without_id() { cut -f 2- | LC_ALL=C sort; }

# The taxon umgap finds for each peptide, one per line.
pept2lca() { { echo '>q'; printf '%s\n' "$@"; } | umgap pept2lca "${WORK}/tryptic/tryptic.index" | tail -n +2; }

build kmer
kmer_rc=$?
build tryptic
tryptic_rc=$?

# The contents of each index, as kmer<TAB>taxon rows. Empty when the index is missing.
umgap printindex "${WORK}/kmer/9-mer.index" > "${WORK}/kmer-index.tsv" 2> /dev/null
umgap printindex "${WORK}/tryptic/tryptic.index" > "${WORK}/tryptic-index.tsv" 2> /dev/null


section "kmer mode"
check_true "the build succeeds" [ "$kmer_rc" -eq 0 ]
check_true "taxons.tsv is the fixture" cmp -s <(table kmer taxons) "${FIXTURES}/taxons.tsv"
check "uniprot_entries.tsv has the fixture rows" \
    "$(table kmer uniprot_entries | rows_without_id)" "$(rows_without_id < "${FIXTURES}/uniprot_entries.tsv")"
check "the index has every 9-mer of the corpus and no other" \
    "$(cut -f 1 "${WORK}/kmer-index.tsv" | LC_ALL=C sort)" \
    "$(cut -f 7 "${FIXTURES}/uniprot_entries.tsv" \
        | gawk '{ for (i = 1; i + 8 <= length($0); i++) print substr($0, i, 9) }' | LC_ALL=C sort -u)"
check "a 9-mer of one protein maps to its taxon" \
    "$(grep '^AAGGKEIVW' "${WORK}/kmer-index.tsv")" $'AAGGKEIVW\t9503'
check "a 9-mer of three taxa maps to their LCA" \
    "$(grep '^GEFIHPWQC' "${WORK}/kmer-index.tsv")" $'GEFIHPWQC\t8287'


section "tryptic mode"
check_true "the build succeeds" [ "$tryptic_rc" -eq 0 ]
check_true "lineages.tsv is the fixture" cmp -s <(table tryptic lineages) "${FIXTURES}/lineages.tsv"
check "uniprot_entries.tsv has the fixture rows" \
    "$(table tryptic uniprot_entries | rows_without_id)" "$(rows_without_id < "${FIXTURES}/uniprot_entries.tsv")"
check "a peptide of one taxon maps to it" "$(pept2lca YSEDVFR)" "8503"
check "a peptide of several taxa maps to their LCA" "$(pept2lca AAGGK)" "1"
check_true "tryptic.index is not empty" [ -s "${WORK}/tryptic-index.tsv" ]
check "a peptide with an asparagine maps to its taxon" "$(pept2lca WNDET)" "8502"
check "the index has every peptide with an LCA in sequences.tsv and no other" \
    "$(LC_ALL=C sort "${WORK}/tryptic-index.tsv")" \
    "$(table tryptic sequences | cut -f 2,3 | grep -vF '\N' | LC_ALL=C sort)"


summary
