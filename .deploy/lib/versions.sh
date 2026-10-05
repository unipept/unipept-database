# shellcheck shell=bash
#
# How a UniProtKB version is written, read and found: the names of database directories, the
# .version files in them, and the current and previous links that say which one a host serves.
# Sourced through .deploy/lib.sh.

# What a finished database is called under OUTPUT_DIR, as a glob. Narrow on purpose: a swap that
# was interrupted leaves a uniprot-<version>.replaced beside it, and an operator may keep a copy
# under another suffix, and neither is a database to pick as the newest.
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly DATABASE_GLOB='uniprot-[0-9][0-9][0-9][0-9]-[0-9][0-9]'

# Stops on a UniProtKB version not written YYYY-MM, the form every database directory is named in.
valid_version() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}$ ]] || die "a UniProtKB version is written YYYY-MM, not '$1'."
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

# The UniProtKB version the pipeline wrote beside the tables, as YYYY-MM.
uniprot_version_from() {
    local version_file="$1" version

    [ -s "$version_file" ] || die "the pipeline wrote no version in ${version_file}"
    version=$(read_version "$version_file")
    [ -n "$version" ] || die "the version in ${version_file} is empty"
    echo "$version"
}

# The version a host serves is a link in OUTPUT_DIR to its directory, and the API's INDEX_LOCATION
# names the suffix array through it, so switch.sh switches by moving the link. `previous` is the one
# before, for switch.sh --back. Neither is named uniprot-*, so DATABASE_GLOB never takes them for a
# version. Functions rather than settings, since OUTPUT_DIR is only final once the flags are read.
current_link() { echo "${OUTPUT_DIR%/}/current"; }
previous_link() { echo "${OUTPUT_DIR%/}/previous"; }

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
