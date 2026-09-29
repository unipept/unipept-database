# shellcheck shell=bash
################################################################################
# Settings and helpers the scripts in .deploy share. Sourced, never run.       #
################################################################################

# The directory of this file. Not HERE, which belongs to the script that sources it.
DEPLOY_DIR="${BASH_SOURCE%/*}"

# log, checkdep and errorAndExit, the same ones the pipelines and the OpenSearch loader use.
# shellcheck source=../pipelines/lib/common.sh
source "${DEPLOY_DIR}/../pipelines/lib/common.sh"

################################################################################
#                                   Settings                                   #
################################################################################

# The settings more than one script has. Each script adds the ones only it uses, and calls read_conf
# once all of them have a default.

# Where the finished databases are written, one directory per UniProtKB version.
# shellcheck disable=SC2034 # read by the scripts that source this file
OUTPUT_DIR=/mnt/data

# The OpenSearch instance load.sh fills and prune.sh removes from.
# shellcheck disable=SC2034 # read by the scripts that source this file
OPENSEARCH_URL=http://localhost:9200

# Who builds, clones and owns the databases. The API on this host runs as the same user, which is
# what makes every file a build writes one the API can read. opensearch/install.sh creates it and
# gives it OUTPUT_DIR; after that, nothing here needs root.
# shellcheck disable=SC2034 # read by the scripts that source this file
DEPLOY_USER=unipept

# Where opensearch/install.sh installs the scripts a host runs, and their configuration. The build
# host still builds from a checkout, which needs the whole repository.
readonly INSTALL_ROOT=/opt/unipept-database

# The API on this host, which unipept-api's install puts there: its settings, of which INDEX_LOCATION
# is read here, and the script that stops and starts it. A host without them runs no API.
# shellcheck disable=SC2034 # read by the scripts that source this file
API_ENV_FILE=${API_ENV_FILE:-/opt/unipept-api/etc/unipept-api.env}
# shellcheck disable=SC2034 # read by the scripts that source this file
API_DEPLOY=${API_DEPLOY:-/opt/unipept-api/lib/deploy.sh}

# The lock that keeps loads and switches apart. One per host, as the OpenSearch it guards is, whatever
# OUTPUT_DIR a run is given; /run/lock is there for every user to take one in.
OPENSEARCH_LOCK=${OPENSEARCH_LOCK:-/run/lock/unipept-opensearch.lock}

# What this host decides. Read after the defaults, so it wins over them, and before the arguments
# are parsed, so a flag wins over both. One file per host: a checkout's own deploy.conf where it has
# one, which is how a checkout is run on its own; the installed one beside these scripts, as
# install.sh lays them out; and otherwise this host's installed one, so build.sh in a checkout reads
# the same settings as the scripts installed beside it.
DEPLOY_CONF="${DEPLOY_DIR}/deploy.conf"
if [ ! -f "$DEPLOY_CONF" ]; then
    if [ -f "${DEPLOY_DIR}/../etc/deploy.conf" ]; then
        DEPLOY_CONF="${DEPLOY_DIR}/../etc/deploy.conf"
    else
        DEPLOY_CONF="${INSTALL_ROOT}/etc/deploy.conf"
    fi
fi

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

# Stops on a UniProtKB version not written YYYY-MM, the form every database directory is named in.
valid_version() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}$ ]] || die "a UniProtKB version is written YYYY-MM, not '$1'."
}

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

# build.sh and clone.sh write what the API serves, so they run as the user the API reads as. Run as
# root, they leave a database owned by root: one the next run as DEPLOY_USER cannot replace, and
# one whose readability check passes only because root reads everything. verify.sh and load.sh
# write nothing there, but both check through that same readability check, so they refuse root
# for that reason alone. prune.sh removes databases, so it runs as the user who owns them.
refuse_root() {
    [ "$(id -u)" -ne 0 ] \
        || die "do not run this as root. Run it as ${DEPLOY_USER}, for example: sudo -iu ${DEPLOY_USER}. Only .deploy/opensearch/install.sh needs root."
}

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

# The version a .version file holds, as YYYY-MM. The file holds YYYY.MM, which is the form the API
# reads; the directory name has always used dashes. Prints nothing for an empty file.
read_version() {
    tr -d '[:space:]' < "$1" | tr '.' '-'
}

# The version a database directory is named after, as YYYY-MM, given the directory or the
# suffix-array inside it. Fails for a directory that is not named after one.
database_version_of() {
    local name="${1%/}"

    name="${name%/suffix-array}"
    name="${name##*/}"
    case "$name" in uniprot-*) echo "${name#uniprot-}" ;; *) return 1 ;; esac
}

# The newest database under OUTPUT_DIR, as YYYY-MM. The glob expands in order, so the last one
# that is a directory is the newest.
latest_version() {
    local newest='' candidate

    # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
    for candidate in "${OUTPUT_DIR}"/${DATABASE_GLOB}; do
        [ -d "$candidate" ] && newest="$candidate"
    done

    [ -n "$newest" ] || die "found no database in ${OUTPUT_DIR}."
    database_version_of "$newest"
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
# only call the functions above and read the lists they read.
verify_database() {
    local index="$1" status=0

    check_index "$index" || status=1
    check_index_version "$index" || status=1
    return "$status"
}

# Warns when OpenSearch's disk is past its low watermark, 85% unless the cluster says otherwise.
# Past it OpenSearch places no new shard on that node, and at the flood stage, 95%, it makes every
# index read-only, so a load running then fails part way. Each loaded version keeps its index until
# .deploy/prune.sh removes it, so this is how running out is heard about before a load breaks on it.
# Says nothing when OpenSearch cannot be asked: the load that follows reports that itself.
warn_opensearch_disk() {
    local url="$1" watermark used

    watermark=$(curl -s -f --max-time 10 \
        "${url}/_cluster/settings?include_defaults=true&flat_settings=true&filter_path=*.cluster.routing.allocation.disk.watermark.low" 2>/dev/null \
        | sed -n 's/.*"cluster.routing.allocation.disk.watermark.low":"\([0-9]*\)%".*/\1/p') || true
    [ -n "$watermark" ] || watermark=85

    used=$(curl -s -f --max-time 10 "${url}/_cat/allocation?h=disk.percent" 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ && $1 > max { max = $1 } END { if (max != "") print max }') || true
    [ -n "$used" ] || return 0

    if [ "$used" -ge "$watermark" ]; then
        echo "WARN OpenSearch's disk is ${used}% full, past its ${watermark}% watermark. A load can fail part way once it reaches 95%; .deploy/prune.sh --keep N removes old versions." 1>&2
    fi
}

# The UniProtKB version the pipeline wrote beside the tables, as YYYY-MM.
uniprot_version_from() {
    local version_file="$1" version

    [ -s "$version_file" ] || die "the pipeline wrote no version in ${version_file}"
    version=$(read_version "$version_file")
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

################################################################################
#                          The version a host serves                           #
################################################################################

# The version a host serves is a link in OUTPUT_DIR to its directory, and the API's INDEX_LOCATION
# names the suffix array through it, so switch.sh switches by moving the link. `previous` is the one
# before, for switch.sh --back. Neither is named uniprot-*, so DATABASE_GLOB never takes them for a
# version. Functions rather than settings, since OUTPUT_DIR is only final once the flags are read.
current_link() { echo "${OUTPUT_DIR}/current"; }
previous_link() { echo "${OUTPUT_DIR}/previous"; }

# The version a link points at, as YYYY-MM. Fails for no link, or one to no version's directory.
linked_version() {
    local target

    target=$(readlink "$1") || return 1
    database_version_of "$target"
}

# Points a link at a target in one rename, so a reader finds the old target or the new one and
# never neither. Relative targets stay relative, so OUTPUT_DIR can move with its links.
point_link() {
    local link="$1" target="$2"

    ln -sfn "$target" "${link}.new"
    mv -T "${link}.new" "$link"
}

# INDEX_LOCATION in the API's settings on this host, or nothing where there are none.
api_index_location() {
    [ -r "$API_ENV_FILE" ] || return 0
    sed -n 's/^INDEX_LOCATION=//p' "$API_ENV_FILE" | tail -n 1
}

# The version this host serves, as YYYY-MM: what current points at, or, on a host that has no current
# link yet, what INDEX_LOCATION names. Nothing where neither says.
served_version() {
    linked_version "$(current_link)" 2> /dev/null \
        || database_version_of "$(api_index_location)" 2> /dev/null \
        || true
}

# Replacing the files of the version this host serves, under an API that has them open, is not a
# switch: it would serve other files from its next start, with nothing checked. Switch away first.
refuse_replacing_served() {
    [ "$(served_version)" != "$1" ] \
        || die "${1} is the version this host serves, so its files are not replaced under the running API. ${2}Switch this host to another version with switch.sh first."
}

# Loads and switches exclude each other: a switch stops OpenSearch, which breaks a load running then.
# A load takes OPENSEARCH_LOCK shared, so loads of different versions still run side by side, and a
# switch takes it exclusively, from its checks to its end. On file descriptor 9, held until the
# script exits. Fails, rather than waits: 1 where the other holds it, 2 where the lock cannot be
# opened at all, which says so.
take_opensearch_lock() {
    { exec 9>> "$OPENSEARCH_LOCK"; } 2> /dev/null || {
        echo "Error: cannot open the lock ${OPENSEARCH_LOCK} as $(id -un)." 1>&2
        return 2
    }
    flock -n "$1" 9
}

