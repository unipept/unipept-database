#!/usr/bin/env bash
#
# Prepares a host to build, clone and hold a Unipept database: the user that owns the databases,
# the tools build.sh, clone.sh and load.sh run, and the scripts a host runs, installed where they do
# not depend on a checkout. Run as root. Run it with --help for the options. opensearch/install.sh
# runs this first, and then sets up the OpenSearch instance load.sh fills.
#
# This and opensearch/install.sh are the only steps that need root. Afterwards DEPLOY_USER owns
# OUTPUT_DIR and has every tool it needs, so build.sh and clone.sh run as that user without sudo,
# as the API's deploy does.
#
# For the Ubuntu 24.04 LTS the servers run: it installs through apt.
#
# Flow:
#   1. Check that this runs as root.
#   2. Create DEPLOY_USER, or give an account that already exists a login shell: clone.sh copies
#      over ssh as that user, and sshd needs a shell to run a remote command.
#   3. Install the tools build.sh, clone.sh and load.sh use, the ones not installed already.
#   4. Create OUTPUT_DIR owned by DEPLOY_USER, and hand it the databases a run as root left.
#   5. Install the scripts a host runs, and what they call, from this checkout into INSTALL_ROOT, as
#      the checkout lays them out, each directory swapped in whole; and write etc/deploy.conf there
#      unless it is already there.
#   6. Allow DEPLOY_USER to stop and start OpenSearch through sudo, and nothing else, which is what
#      switch.sh needs to switch without root.
#   7. Say what is left to do, on this host.
#
# A second run with the same settings changes nothing.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh" || exit 2

# The settings only this script has.

# Where the scripts a host runs are installed. /opt/unipept-database, as the API's are in
# /opt/unipept-api; a flag for a test that installs more than one host into one machine.
PREFIX="$INSTALL_ROOT"

read_install_conf "$@"

# What build.sh, clone.sh and load.sh run, by package: git, cmake and a C toolchain for the index
# build, lz4, pv, pigz, gawk, unzip, uuidgen, xmllint and curl for the pipeline, python3-requests
# for the loader, ssh and scp for the clone, and gnupg for the key of the OpenSearch repository
# opensearch/install.sh adds. The Rust toolchain is not here: the repository pins its own through
# rust-toolchain.toml, which rustup, installed as DEPLOY_USER, follows.
readonly TOOL_PACKAGES=(
    git cmake build-essential curl ca-certificates gnupg
    lz4 pv pigz gawk unzip uuid-runtime libxml2-utils
    python3 python3-requests
    openssh-client
)

readonly SUDOERS_FILE=/etc/sudoers.d/unipept-opensearch
readonly MARKER='# Written by unipept-database .deploy/server/install.sh. Edit that, not this.'

usage() {
    cat <<'USAGE'
Prepares a host to build, clone and hold a Unipept database: the user that owns the databases, the
tools the scripts run, and the scripts themselves in /opt/unipept-database. Run as root.
.deploy/server/opensearch/install.sh runs this, and then sets up OpenSearch.

  .deploy/server/install.sh [OPTIONS]

  --user USER                who builds, clones and owns the databases
  --output-dir DIR           where the databases are, handed to that user
  --prefix DIR               where the scripts a host runs are installed, default
                             /opt/unipept-database
  --help                     print this message

A flag wins over deploy.conf, which wins over the defaults in this script. The deploy.conf read is the
clone's own .deploy/deploy.conf where it has one, and otherwise the install's etc/deploy.conf,
/opt/unipept-database/etc/deploy.conf or the one under --prefix.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) need_value "$1" "${2-}"; DEPLOY_USER="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix) need_value "$1" "${2-}"; PREFIX="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) unknown_option "$1" ;;
        esac
    done
}

# The user build.sh and clone.sh run as. A home, because rustup and the ssh key live in it. A real
# shell, because clone.sh runs commands on the remote host over ssh as this user, and sshd runs a
# remote command through the login shell: nologin answers and runs nothing. The API's install makes
# the same account the same way, so the two can run in either order.
ensure_user() {
    if id "$DEPLOY_USER" > /dev/null 2>&1; then
        case "$(getent passwd "$DEPLOY_USER" | cut -d: -f7)" in
            *nologin | *false)
                usermod --shell /bin/bash "$DEPLOY_USER"
                log "Gave ${DEPLOY_USER} a login shell, for ssh." ;;
        esac
    else
        useradd --create-home --shell /bin/bash "$DEPLOY_USER"
        log "Created the ${DEPLOY_USER} user."
    fi
}

# Only the packages that are missing, so a second run does not reach apt at all.
install_tools() {
    local package missing=()

    for package in "${TOOL_PACKAGES[@]}"; do
        [ "$(dpkg-query --showformat='${db:Status-Status}' --show "$package" 2> /dev/null)" = installed ] \
            || missing+=("$package")
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        log "The tools build.sh, clone.sh and load.sh use are installed."
        return
    fi

    log "Installing ${missing[*]}."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}

# The directory the databases are written to, owned by DEPLOY_USER so a build or a clone creates
# and renames in it without root. Only the directory itself and what build.sh and clone.sh write in
# it change owner: OUTPUT_DIR is often a volume that holds other things, OpenSearch's data among
# them, whose owners are not this script's to change.
prepare_output_dir() {
    local entry

    if [ ! -d "$OUTPUT_DIR" ]; then
        install -d -m 0755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$OUTPUT_DIR"
        log "Created ${OUTPUT_DIR} for ${DEPLOY_USER}."
        return
    fi

    [ "$(stat -c %U "$OUTPUT_DIR")" = "$DEPLOY_USER" ] || {
        chown "${DEPLOY_USER}:" "$OUTPUT_DIR"
        log "Gave ${OUTPUT_DIR} to ${DEPLOY_USER}."
    }

    # What an earlier run as root left: databases the next run could not replace, and staging
    # directories and the leftover of an interrupted swap, which it could not remove. A database is
    # a few dozen files, so this is quick.
    # shellcheck disable=SC2231 # DATABASE_GLOB is a glob, and has to expand
    for entry in "$OUTPUT_DIR"/${DATABASE_GLOB} "$OUTPUT_DIR"/${DATABASE_GLOB}.replaced \
        "${OUTPUT_DIR}/.build" "${OUTPUT_DIR}/.clone"; do
        [ -e "$entry" ] || continue
        if [ -n "$(find "$entry" ! -user "$DEPLOY_USER" -print -quit)" ]; then
            chown -R "${DEPLOY_USER}:" "$entry"
            log "Gave ${entry} to ${DEPLOY_USER}."
        fi
    done
}

# The scripts every host runs, where they do not depend on a checkout: a host that only clones and
# serves needs no clone of this repository, and the path is the same on every host, so distribute.sh
# can rely on it. Laid out as the checkout lays them out, deploy/ as .deploy/, so each script finds
# lib.sh, the loader and the rest by the same relative path in both. Owned by root, since only this
# script changes them; etc/ belongs to root too, since this reads deploy.conf as root.
#
# Staged whole, then swapped in a directory at a time, each by a rename: nothing the checkout no
# longer has lingers, and no directory is ever half written. etc/ is not touched.
#
# From the checkout this runs in, so a host is updated by running this again from a checkout of the
# commit to install, which INSTALLED then names.
install_scripts() {
    local repository="${DEPLOY_DIR}/.." staging="${PREFIX}/.staging" entry commit

    # A load, a switch or a prune running from these files while they are replaced could pair a new
    # lib.sh with an old script, or start opensearch/load.sh from the new release halfway through a
    # run of the old one. Each holds OPENSEARCH_LOCK, so this holds it exclusively until it is done,
    # and refuses while one runs. /run/lock is emptied at boot, so the file may not be there yet: it
    # is made the deploy user's, as the first script to take it would have made it.
    [ -e "$OPENSEARCH_LOCK" ] || install -m 0644 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /dev/null "$OPENSEARCH_LOCK"
    take_opensearch_lock -x || die "$(lock_refused $?) Install once it has finished."

    rm -rf "${staging:?}"
    install -d -m 0755 -o root -g root "$PREFIX"
    install -d -m 0755 "${staging}/deploy/lib" "${staging}/deploy/server" \
        "${staging}/opensearch/mappings" "${staging}/pipelines/lib"
    install -m 0644 "${repository}/.deploy/lib.sh" "${staging}/deploy/"
    install -m 0644 "${repository}/.deploy/lib/"*.sh "${staging}/deploy/lib/"
    # The scripts every host runs. Not the installs, which run from a checkout, nor build.sh and
    # distribute.sh, which need one.
    install -m 0755 "${repository}/.deploy/server/"{clone.sh,load.sh,verify.sh,switch.sh,prune.sh} "${staging}/deploy/server/"
    install -m 0644 "${repository}/opensearch/"{lib.sh,bulk_load.py} "${staging}/opensearch/"
    install -m 0755 "${repository}/opensearch/load.sh" "${staging}/opensearch/"
    install -m 0644 "${repository}/opensearch/mappings/uniprot_entries.json" "${staging}/opensearch/mappings/"
    install -m 0644 "${repository}/pipelines/lib/common.sh" "${staging}/pipelines/lib/"

    # Each entry swapped in by a rename, what is loaded before what loads it, so a script started
    # meanwhile finds the files of its own release: the pipelines' library, then the loader, then the
    # scripts. The old one is moved aside before the new one takes its name, and removed once it has.
    for entry in pipelines opensearch deploy; do
        rm -rf "${PREFIX:?}/${entry}.old"
        [ ! -e "${PREFIX}/${entry}" ] || mv "${PREFIX}/${entry}" "${PREFIX}/${entry}.old"
        mv "${staging}/${entry}" "${PREFIX}/${entry}"
        rm -rf "${PREFIX:?}/${entry}.old"
    done
    rmdir "$staging"

    install -d -m 0755 -o root -g root "${PREFIX}/etc"
    if [ ! -f "${PREFIX}/etc/deploy.conf" ]; then
        sed "s#^OUTPUT_DIR=.*#OUTPUT_DIR=${OUTPUT_DIR}#" "${repository}/.deploy/deploy.conf.example" > "${PREFIX}/etc/deploy.conf"
        chmod 0644 "${PREFIX}/etc/deploy.conf"
        log "Wrote ${PREFIX}/etc/deploy.conf. Edit it, as root, for what this host decides."
    fi

    # As root, of a checkout another user owns, which git refuses to read unless told to trust it.
    commit=$(git -c safe.directory='*' -C "$repository" rev-parse HEAD 2>/dev/null || echo unknown)
    printf 'commit: %s\ninstalled: %s\n' "$commit" "$(date -u +'%F %T UTC')" > "${PREFIX}/INSTALLED"
    log "Installed the scripts of ${commit} in ${PREFIX}."
}

# switch.sh stops and starts OpenSearch as DEPLOY_USER, which a system service allows root alone.
# Exactly those two commands, by full path, as sudo matches them, and checked by visudo before it is
# put in place: a sudoers file sudo cannot parse stops sudo for everyone on the host.
allow_opensearch_restart() {
    local rule staged

    rule="${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl stop opensearch, /usr/bin/systemctl start opensearch"
    if [ -f "$SUDOERS_FILE" ] && [ "$(cat "$SUDOERS_FILE")" = "$(printf '%s\n%s' "$MARKER" "$rule")" ]; then
        return 0
    fi

    staged=$(mktemp)
    printf '%s\n%s\n' "$MARKER" "$rule" > "$staged"
    visudo -c -q -f "$staged" > /dev/null || { rm -f "$staged"; die "visudo refuses the rule for ${DEPLOY_USER}, so it is not written."; }
    install -m 0440 -o root -g root "$staged" "$SUDOERS_FILE"
    rm -f "$staged"
    log "Allowed ${DEPLOY_USER} to stop and start OpenSearch through sudo, for switch.sh."
}

parse_arguments "$@"

[ "$(id -u)" -eq 0 ] || die "run this as root. It is one of the two steps that need it."
require apt-get dpkg-query getent useradd usermod visudo:sudo flock:util-linux

ensure_user
install_tools
prepare_output_dir
install_scripts
allow_opensearch_restart

cat >&2 <<EOF

Still to do on this host:
  1. As root, say what this host decides in ${PREFIX}/etc/deploy.conf.
As ${DEPLOY_USER} (sudo -iu ${DEPLOY_USER}), none of it as root:
  2. To clone from another host: an ssh key in ~/.ssh that ${DEPLOY_USER} on that host accepts.
     ${PREFIX}/deploy/server/clone.sh then copies a database, and ${PREFIX}/deploy/server/load.sh
     loads its proteins.
  3. To build: clone unipept-database, which build.sh needs whole, and install Rust with rustup
     (https://rustup.rs); the repository pins the toolchain. .deploy/build.sh in that clone reads
     the same deploy.conf.
  4. On a host that runs the API, once its first version is here and loaded: point
     ${OUTPUT_DIR}/current at it (ln -s uniprot-YYYY-MM ${OUTPUT_DIR}/current), and INDEX_LOCATION
     in the API's settings at ${OUTPUT_DIR}/current/suffix-array. switch.sh changes the version
     from then on.
EOF
log "The user and the scripts are ready."
