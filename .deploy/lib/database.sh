# shellcheck shell=bash
#
# What a finished database holds, how it is checked, and how one is put in place. Sourced through
# .deploy/lib.sh, after versions.sh, whose read_version and database_version_of it uses.

# What the pipeline writes. uniprot_entries feeds the suffix array and OpenSearch; the other six
# are the datastore the API reads.
# shellcheck disable=SC2034 # read by the scripts that source this file
DATASTORE_TABLES=(taxons lineages interpro_entries go_terms ec_numbers proteomes)
# shellcheck disable=SC2034 # read by the scripts that source this file
PIPELINE_TABLES=(uniprot_entries "${DATASTORE_TABLES[@]}")

# What the API needs under the directory it is pointed at, relative to it. The same list as
# INDEX_FILES in unipept-api/.deploy/lib.sh: that repository starts a service against this layout
# and this one produces it, so the two have to agree. A change here is a change there. The tables
# come from DATASTORE_TABLES, so one fill_datastore writes is one this checks.
INDEX_FILES=(.version sa.bin proteins.bin mapping.bin datastore/sampledata.json)
for datastore_table in "${DATASTORE_TABLES[@]}"; do
    INDEX_FILES+=("datastore/${datastore_table}.tsv")
done
unset datastore_table
readonly INDEX_FILES

# What the API opens when it is there and runs without. Searches are slower without it.
readonly OPTIONAL_INDEX_FILES=(kmer_table.bin)

# Reports every index file that is missing, empty or unreadable, rather than the first, and returns
# non-zero if any of them was. An empty file passes the API's own readable check and fails the
# service later, so the test here is on content.
#
# Readable means readable by whoever runs this. Root reads everything, so as root an unreadable
# file would pass: every script that calls this refuses root first.
check_index() {
    local index="$1" relative missing=0 hidden=''

    [ -d "$index" ] || { echo "FAIL ${index} is not a directory" 1>&2; return 1; }

    # A directory that cannot be entered hides the files in it, which would read as missing and
    # send the operator to rebuild rather than to fix a permission. It is named once, and what is
    # in it is not reported again.
    if [ ! -r "$index" ] || [ ! -x "$index" ]; then
        echo "FAIL ${index} is not readable" 1>&2
        return 1
    fi
    if [ -d "${index}/datastore" ] && { [ ! -r "${index}/datastore" ] || [ ! -x "${index}/datastore" ]; }; then
        echo "FAIL datastore/ is not readable" 1>&2
        missing=1
        hidden=datastore/
    fi

    for relative in "${INDEX_FILES[@]}"; do
        if [ -n "$hidden" ] && [[ "$relative" == "$hidden"* ]]; then
            continue
        elif [ ! -e "${index}/${relative}" ]; then
            echo "FAIL ${relative} is missing" 1>&2
            missing=1
        elif [ ! -r "${index}/${relative}" ]; then
            echo "FAIL ${relative} is not readable" 1>&2
            missing=1
        elif [ ! -s "${index}/${relative}" ]; then
            echo "FAIL ${relative} is empty" 1>&2
            missing=1
        fi
    done

    for relative in "${OPTIONAL_INDEX_FILES[@]}"; do
        [ -s "${index}/${relative}" ] \
            || echo "WARN ${relative} is missing; the API runs without it and searches are slower" 1>&2
    done

    return "$missing"
}

# The directory a build writes is named after the version inside it. A pair that disagrees means
# one of the two came from somewhere else.
check_index_version() {
    local index="$1" named version

    named=$(database_version_of "$index") || return 0
    # Missing, empty or unreadable is check_index's to report, and a version read from a file that
    # cannot be read would only add a second, misleading failure.
    { [ -s "${index}/.version" ] && [ -r "${index}/.version" ]; } || return 0

    version=$(read_version "${index}/.version")
    [ "$named" = "$version" ] || {
        echo "FAIL the directory says ${named} and .version says ${version}" 1>&2
        return 1
    }
}

# The whole contract a database is held to before the API is pointed at it, reporting every
# failure rather than the first. build.sh, clone.sh, load.sh and verify.sh all check through this,
# so a check added here is one all four make. clone.sh also sends it to the remote host, so it may
# only call check_index, check_index_version, database_version_of and read_version, and read the
# lists they read: clone.sh sends exactly those.
verify_database() {
    local index="$1" status=0

    check_index "$index" || status=1
    check_index_version "$index" || status=1
    return "$status"
}

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
