# shellcheck shell=bash
################################################################################
# Settings and helpers shared by build.sh and clone.sh. Sourced, never run.    #
################################################################################

# Read build.conf first, so what it sets wins over the defaults below, and anything already in the
# environment wins over both. Every assignment here and there uses := for that reason.
DEPLOY_DIR="${BASH_SOURCE%/*}"
: "${UNIPEPT_BUILD_CONF:=${DEPLOY_DIR}/build.conf}"
# shellcheck source=/dev/null
[ -f "$UNIPEPT_BUILD_CONF" ] && source "$UNIPEPT_BUILD_CONF"

# Where the finished database is written, one directory per UniProtKB version.
: "${OUTPUT_DIR:=/mnt/data}"
# Where the repositories are cloned and the tables are built.
: "${SCRATCH_DIR:=$HOME}"
: "${DATABASE_SOURCES:=swissprot,trembl}"

# The host clone.sh copies a finished database from.
: "${REMOTE_ADDRESS:=}"
: "${REMOTE_PORT:=4840}"
: "${REMOTE_USER:=unipept}"
: "${REMOTE_OUTPUT_DIR:=/mnt/data}"
: "${LOCAL_SSH_KEY:=}"

# The OpenSearch instance the proteins are loaded into.
: "${OPENSEARCH_URL:=http://localhost:9200}"

: "${DATABASE_REPO:=https://github.com/unipept/unipept-database.git}"
: "${INDEX_REPO:=https://github.com/unipept/unipept-index.git}"

log() { echo "$(date +'[%s (%F %T)]')" "$@"; }

die() {
    echo "Error: $*" 1>&2
    exit 2
}

checkdep() {
    command -v "$1" > /dev/null 2>&1 || die "this script requires ${2:-$1} to be installed."
}

errorAndExit() {
    local exit_status="$?"
    echo "Error: the deploy script stopped at line ${BASH_LINENO[0]}." 1>&2
    echo "Command '${BASH_COMMAND}' failed with exit status ${exit_status}." 1>&2
    exit 2
}

# The version of UniProtKB the release page names, as YYYY-MM.
latest_uniprot_version() {
    local version
    version=$(curl -s "${UNIPEPT_RELDATE_URL:-https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/reldate.txt}" \
        | head -n 1 | grep -oE '[0-9]{4}_[0-9]{2}' | sed 's/_/-/')
    [ -n "$version" ] || die "could not read the UniProtKB version."
    echo "$version"
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
sources: ${DATABASE_SOURCES}
INFO
}
