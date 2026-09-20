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

die() {
    echo "Error: $*" 1>&2
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
