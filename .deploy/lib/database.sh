# shellcheck shell=bash
#
# What a finished database holds, and how one is put in place. The checks of it are in checks.sh.
# Needs nothing else. Sourced through .deploy/lib.sh.

# What the pipeline writes. uniprot_entries feeds the suffix array and OpenSearch; the other six
# are the datastore the API reads.
DATASTORE_TABLES=(taxons lineages interpro_entries go_terms ec_numbers proteomes)
# shellcheck disable=SC2034 # read by the scripts that source this file
PIPELINE_TABLES=(uniprot_entries "${DATASTORE_TABLES[@]}")

# What the API needs under the directory it is pointed at, relative to it. The API checks for
# exactly these before it starts, so adding or removing one needs the same change on the API side.
# The tables come from DATASTORE_TABLES, so one fill_datastore writes is one check_index_files
# checks.
INDEX_FILES=(.version sa.bin proteins.bin mapping.bin datastore/sampledata.json)
for datastore_table in "${DATASTORE_TABLES[@]}"; do
    INDEX_FILES+=("datastore/${datastore_table}.tsv")
done
unset datastore_table
readonly INDEX_FILES

# What the API opens when it is there and runs without. Searches are slower without it.
# shellcheck disable=SC2034 # read by checks.sh
readonly OPTIONAL_INDEX_FILES=(kmer_table.bin)

# Puts a finished build where the API reads it. The directory it replaces is kept until the rename
# has happened, so an interruption here always leaves one whole database behind.
swap_into_place() {
    local staging="$1" target="$2"
    local previous="${target}.replaced"

    rm -rf "${previous:?}"
    if [ -e "$target" ]; then
        mv "$target" "$previous"
    fi
    mv "$staging" "$target"
    rm -rf "${previous:?}"
}
