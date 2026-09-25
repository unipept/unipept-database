# shellcheck shell=bash
################################################################################
# Settings and helpers shared by build.sh and clone.sh. Sourced, never run.    #
################################################################################

# The directory of this file. Not HERE, which belongs to the script that sources it.
DEPLOY_DIR="${BASH_SOURCE%/*}"

# log, checkdep and errorAndExit, the same ones the pipelines and the OpenSearch loader use.
# shellcheck source=../pipelines/lib/common.sh
source "${DEPLOY_DIR}/../pipelines/lib/common.sh"

################################################################################
#                                   Settings                                   #
################################################################################

# The settings both scripts have. Each script adds the ones only it uses, and calls read_conf once
# all of them have a default.

# Where the finished databases are written, one directory per UniProtKB version.
# shellcheck disable=SC2034 # read by the scripts that source this file
OUTPUT_DIR=/mnt/data

# The OpenSearch instance the proteins are loaded into.
# shellcheck disable=SC2034 # read by the scripts that source this file
OPENSEARCH_URL=http://localhost:9200

# What this host decides. Read after the defaults, so it wins over them, and before the arguments
# are parsed, so a flag wins over both.
DEPLOY_CONF="${DEPLOY_DIR}/deploy.conf"

read_conf() {
    if [ -f "$DEPLOY_CONF" ]; then
        # shellcheck source=/dev/null
        source "$DEPLOY_CONF"
    fi
}

################################################################################
#                                   Helpers                                    #
################################################################################

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

# What a finished database is called under OUTPUT_DIR, as a glob. Narrow on purpose: a swap that
# was interrupted leaves a uniprot-<version>.replaced beside it, and an operator may keep a copy
# under another suffix, and neither is a database to pick as the newest.
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly DATABASE_GLOB='uniprot-[0-9][0-9][0-9][0-9]-[0-9][0-9]'

# The script's own process, captured before any subshell can shadow it. A die inside a command
# substitution only ends that subshell, and the caller then reports the same failure a second time
# through the ERR trap, so die signals the script itself. USR1 rather than TERM, so a real
# interrupt still reads as one. Each script arms the trap that answers it.
readonly MAIN_PID=$$

die() {
    echo "Error: $*" 1>&2
    [ "$$" = "$BASHPID" ] || kill -USR1 "$MAIN_PID" 2>/dev/null
    exit 2
}

# Stops a flag from swallowing the next flag, or nothing at all, as its value.
need_value() {
    local flag="$1" value="$2"

    { [ -n "$value" ] && [[ "$value" != --* ]]; } || die "${flag} requires a value."
}

# What opensearch/load.sh needs. Checked before the work starts: the load is the last step of a
# build that takes days, and load.sh only reports a missing package once it is reached.
check_loader_deps() {
    checkdep lz4
    checkdep pv
    checkdep python3
    python3 -c "import requests" > /dev/null 2>&1 \
        || die "the OpenSearch loader requires the requests package: pip install -r ${DEPLOY_DIR}/../opensearch/requirements.txt"
}

# Reports every index file that is missing, empty or unreadable, rather than the first, and returns
# non-zero if any of them was. An empty file passes the API's own readable check and fails the
# service later, so the test here is on content.
#
# Readable means readable by whoever runs this. Run it as the user the API runs as: root reads
# everything, so as root an unreadable file passes.
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
# one of the two came from somewhere else, which is the defect that made the version a build reads
# and the version it is called by two different things.
check_index_version() {
    local index="$1" name version

    name="${index%/}"
    name="${name%/suffix-array}"
    name="${name##*/}"

    case "$name" in uniprot-*) ;; *) return 0 ;; esac
    # Missing, empty or unreadable is check_index's to report, and a version read from a file that
    # cannot be read would only add a second, misleading failure.
    { [ -s "${index}/.version" ] && [ -r "${index}/.version" ]; } || return 0

    version=$(tr -d '[:space:]' < "${index}/.version" | tr '.' '-')
    [ "${name#uniprot-}" = "$version" ] || {
        echo "FAIL the directory says ${name#uniprot-} and .version says ${version}" 1>&2
        return 1
    }
}

# The UniProtKB version the pipeline wrote beside the tables, as YYYY-MM. The file holds YYYY.MM,
# which is the form the API reads; the directory name has always used dashes.
uniprot_version_from() {
    local version_file="$1" version

    [ -s "$version_file" ] || die "the pipeline wrote no version in ${version_file}"
    version=$(tr -d '[:space:]' < "$version_file" | tr '.' '-')
    [ -n "$version" ] || die "the version in ${version_file} is empty"
    echo "$version"
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
