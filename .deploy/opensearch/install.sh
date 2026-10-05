#!/usr/bin/env bash
#
# Prepares a host to build, clone and hold a Unipept database: the user that owns the databases,
# the tools build.sh, clone.sh and load.sh run, the scripts a host runs, installed where they do not
# depend on a checkout, and the OpenSearch instance load.sh fills.
# Run as root. Run it with --help for the options.
#
# This is the only step that needs root. Afterwards DEPLOY_USER owns OUTPUT_DIR and has every tool
# it needs, so build.sh and clone.sh run as that user without sudo, as the API's deploy does.
#
# For the Ubuntu 24.04 LTS the servers run: it installs through apt and starts through systemd.
#
# It loads nothing. opensearch/load.sh does that, here and after every build.
#
# Flow:
#   1. Check that this runs as root on a host with apt and systemd, and that the OpenSearch it has,
#      if any, can be brought to the pinned version: nothing else is changed on a host where not.
#   2. Create DEPLOY_USER, or give an account that already exists a login shell: clone.sh copies
#      over ssh as that user, and sshd needs a shell to run a remote command.
#   3. Install the tools build.sh, clone.sh and load.sh use, the ones not installed already.
#   4. Create OUTPUT_DIR owned by DEPLOY_USER, and hand it the databases a run as root left.
#   5. Install clone.sh, load.sh, verify.sh, prune.sh, switch.sh, migrate.sh and what they call
#      into INSTALL_ROOT, from this checkout, and write etc/deploy.conf there unless it is already there.
#      Allow DEPLOY_USER to stop and start OpenSearch through sudo, and nothing else, which is what
#      switch.sh needs to switch without root.
#   6. Add the OpenSearch APT repository, unless it is already there.
#   7. Install the pinned version, or upgrade an older one of the same major version to it, keeping
#      the configuration this script writes, and hold it so an unrelated upgrade cannot move it.
#   8. Write the configuration this instance needs, keeping a copy of what was there and the data
#      and log paths it named.
#   9. Write the heap size, and a systemd drop-in giving OpenSearch time to start and starting it
#      again after a failure.
#  10. Enable and start the service, restarting it only when something above changed, and wait
#      for it to answer.
#  11. Set every index to hold no replica.
#  12. Say what is left to do, on this host.
#
# A second run with the same settings changes nothing and restarts nothing.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

# The settings only this script has.

# The version every host runs. Pinned, and held in apt afterwards, so a host cannot drift onto a
# release nothing has been tested against.
# shellcheck source=version.sh
source "${HERE}/version.sh"

# The heap OpenSearch takes, and the one number a host decides. Deliberately small: this host also
# serves the API, which holds the index resident, and unipept-api/.deploy sizes that against the
# memory it can see. Heap taken here is memory that sizing does not know about. The README and
# deploy.conf.example point here rather than repeat this.
#
# Empty keeps what the host already has, and a host that has nothing gets DEFAULT_HEAP, so a rerun
# without --heap does not undo the one it was provisioned with.
OPENSEARCH_HEAP=
readonly DEFAULT_HEAP=4g

# What the instance binds to. The security plugin is off, so nothing authenticates a request, and
# an instance reachable from another host is an open datastore. Change this only together with
# turning the security plugin back on.
OPENSEARCH_BIND=127.0.0.1
OPENSEARCH_PORT=9200

# Where the instance keeps its data and logs. Empty keeps what the configuration already names,
# which on a host set up by hand may be another volume, and a fresh install gets the package's.
OPENSEARCH_DATA_DIR=
OPENSEARCH_LOG_DIR=

# Seconds to wait for the service to answer after it is started.
OPENSEARCH_READY_TIMEOUT=180

# Where the scripts a host runs are installed. /opt/unipept-database, as unipept-api's are in
# /opt/unipept-api; a flag for a test that installs more than one host into one machine.
PREFIX="$INSTALL_ROOT"

# The configuration of the install this run makes or updates, so --prefix reads its own and not
# /opt/unipept-database's; a checkout's own deploy.conf still comes first, as lib.sh has it. Found
# before the arguments are parsed, since read_conf comes first for a flag to win over it.
for ((argument = 1; argument < $#; argument++)); do
    [ "${!argument}" != --prefix ] || { next=$((argument + 1)); PREFIX="${!next}"; }
done
[ -f "${DEPLOY_DIR}/deploy.conf" ] || DEPLOY_CONF="${PREFIX}/etc/deploy.conf"

# This runs as root, and sources that file. An installed one is root's, as install_scripts leaves
# it, and one another user could write would hand that user root.
if [ "$DEPLOY_CONF" != "${DEPLOY_DIR}/deploy.conf" ] && [ -e "$DEPLOY_CONF" ]; then
    case "$(stat -c '%U %A' "$DEPLOY_CONF")" in
        "root -rw-r--r--" | "root -rw-------" | "root -r--r--r--" | "root -r--------") ;;
        *) die "${DEPLOY_CONF} can be written by someone other than root, and this runs as root and reads it. Make it root's, mode 0644, after checking what is in it." ;;
    esac
fi

read_conf

# What build.sh, clone.sh and load.sh run, by package: git, cmake and a C toolchain for the index
# build, lz4, pv, pigz, gawk, unzip, uuidgen, xmllint and curl for the pipeline, python3-requests
# for the loader, ssh and scp for the clone, and gnupg for the OpenSearch repository's key below.
# The Rust toolchain is not here: the repository pins its own through rust-toolchain.toml, which
# rustup, installed as DEPLOY_USER, follows.
readonly TOOL_PACKAGES=(
    git cmake build-essential curl ca-certificates gnupg
    lz4 pv pigz gawk unzip uuid-runtime libxml2-utils
    python3 python3-requests
    openssh-client
)

# OpenSearch publishes one apt repository per major version, so the one to add follows the pin.
readonly OPENSEARCH_MAJOR="${OPENSEARCH_VERSION%%.*}"
readonly APT_LIST="/etc/apt/sources.list.d/opensearch-${OPENSEARCH_MAJOR}.x.list"
readonly APT_KEYRING=/usr/share/keyrings/opensearch-keyring.gpg
readonly CONFIG_FILE=/etc/opensearch/opensearch.yml
readonly HEAP_FILE=/etc/opensearch/jvm.options.d/heap.options
readonly UNIT_DROPIN=/etc/systemd/system/opensearch.service.d/unipept.conf
readonly SUDOERS_FILE=/etc/sudoers.d/unipept-opensearch

# How long systemd gives OpenSearch to start, and how soon it starts it again after a failure. The
# package gives it 75 seconds and never starts it again. That is enough on its own, but not while
# unattended upgrades restart it and are busy with the same disk: on a host whose index is not in
# the page cache, such as one running the API's preloaded variant, that start ran out every time,
# and the host was left without OpenSearch until someone noticed, for months once.
readonly START_TIMEOUT=600
readonly RESTART_DELAY=30
readonly MARKER='# Written by unipept-database .deploy/opensearch/install.sh. Edit that, not this.'

# Whether this run wrote a file the service reads, and so has to restart it.
CHANGED=false

usage() {
    cat <<'USAGE'
Prepares a host to build, clone and hold a Unipept database: the user that owns the databases, the
tools the scripts run, the scripts themselves in /opt/unipept-database, and the OpenSearch instance
the proteins are loaded into. Run as root; it is the only step that needs it.

  .deploy/opensearch/install.sh [OPTIONS]

  --heap SIZE              the heap OpenSearch takes, for example 8g; default what the host has,
                           or 4g
  --bind ADDRESS           the address it listens on
  --port PORT              the port it listens on
  --data-dir DIR           where it keeps its data; default what the configuration names
  --log-dir DIR            where it writes its logs; default what the configuration names
  --user USER              who builds, clones and owns the databases
  --output-dir DIR         where the databases are, handed to that user
  --prefix DIR             where the scripts a host runs are installed, default /opt/unipept-database
  --help                   print this message

A flag wins over deploy.conf, which wins over the defaults in this script. The deploy.conf read is the
clone's own .deploy/deploy.conf where it has one, and otherwise the install's etc/deploy.conf,
/opt/unipept-database/etc/deploy.conf or the one under --prefix.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --heap) need_value "$1" "${2-}"; OPENSEARCH_HEAP="$2"; shift 2 ;;
            --bind) need_value "$1" "${2-}"; OPENSEARCH_BIND="$2"; shift 2 ;;
            --port) need_value "$1" "${2-}"; OPENSEARCH_PORT="$2"; shift 2 ;;
            --data-dir) need_value "$1" "${2-}"; OPENSEARCH_DATA_DIR="$2"; shift 2 ;;
            --log-dir) need_value "$1" "${2-}"; OPENSEARCH_LOG_DIR="$2"; shift 2 ;;
            --user) need_value "$1" "${2-}"; DEPLOY_USER="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix) need_value "$1" "${2-}"; PREFIX="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [ -z "$OPENSEARCH_HEAP" ] || [[ "$OPENSEARCH_HEAP" =~ ^[0-9]+[mg]$ ]] \
        || die "--heap takes a size like 4g or 512m, not '${OPENSEARCH_HEAP}'."
    [[ "$OPENSEARCH_PORT" =~ ^[0-9]+$ ]] || die "--port takes a number, not '${OPENSEARCH_PORT}'."
}

# The value a YAML configuration gives a top-level key, or nothing.
setting_in() {
    local file="$1" key="$2"

    [ -f "$file" ] || return 0
    sed -n "s/^${key//./\\.}:[[:space:]]*//p" "$file" | tail -n 1
}

# Writes the content on stdin to the file only when it differs from what is there.
write_if_changed() {
    local target="$1" content

    content="$(cat)"
    if [ -f "$target" ] && [ "$(cat "$target")" = "$content" ]; then
        return 0
    fi
    printf '%s\n' "$content" > "$target"
    CHANGED=true
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
# serves needs no clone of this repository, and the path is the same on every host, so
# distribute.sh and the API's deploy can rely on it. The layout keeps the paths the scripts use
# between each other. Owned by root, since only this script changes them; etc/ belongs to
# root too, since install.sh reads deploy.conf as root.
#
# From the checkout this runs in, so a host is updated by running this again from a checkout of the
# commit to install, which INSTALLED then names.
install_scripts() {
    local repository="${HERE}/../.." commit

    install -d -m 0755 "$PREFIX" "${PREFIX}/bin" "${PREFIX}/bin/lib" "${PREFIX}/opensearch/mappings" "${PREFIX}/pipelines/lib"
    install -m 0755 "${repository}/.deploy/"{lib.sh,clone.sh,load.sh,verify.sh,prune.sh,switch.sh,migrate.sh} "${PREFIX}/bin/"
    install -m 0644 "${repository}/.deploy/lib/"*.sh "${PREFIX}/bin/lib/"
    install -m 0755 "${repository}/opensearch/load.sh" "${PREFIX}/opensearch/"
    # What an earlier release installed: it moved an alias the API no longer queries, and closed the
    # index the API did.
    rm -f "${PREFIX}/opensearch/activate.sh"
    install -m 0644 "${repository}/opensearch/"{lib.sh,bulk_load.py} "${PREFIX}/opensearch/"
    install -m 0644 "${repository}/opensearch/mappings/uniprot_entries.json" "${PREFIX}/opensearch/mappings/"
    install -m 0644 "${repository}/pipelines/lib/common.sh" "${PREFIX}/pipelines/lib/"

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

add_repository() {
    if [ -f "$APT_KEYRING" ] && [ -f "$APT_LIST" ]; then
        log "The OpenSearch repository is already configured."
        return
    fi

    log "Adding the OpenSearch repository."
    curl -sSfL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
        | gpg --dearmor --batch --yes -o "$APT_KEYRING"
    echo "deb [signed-by=${APT_KEYRING}] https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_MAJOR}.x/apt stable main" \
        > "$APT_LIST"
}

# What dpkg knows of OpenSearch, as INSTALLED_STATUS and INSTALLED_VERSION. A package that was
# removed but not purged still has a version, so it reads as not installed; one an earlier run left
# unpacked or half-configured does not, since what is on disk is still that version.
read_installed() {
    INSTALLED_STATUS='' INSTALLED_VERSION=''
    read -r INSTALLED_STATUS INSTALLED_VERSION < <(dpkg-query --showformat='${db:Status-Status} ${Version}' \
        --show opensearch 2> /dev/null) || true
    case "$INSTALLED_STATUS" in
        '' | not-installed | config-files) INSTALLED_VERSION='' ;;
    esac
}

# Stops on an OpenSearch the pin cannot be reached from, before anything on the host is changed.
#
# Raising the pin is how a host is kept patched, so an older release of the same major version is
# upgraded later on. Not another major version: data a newer major version writes cannot be read by
# the one before, so that upgrade cannot be undone and is a decision of its own. Nor back down, which
# OpenSearch does not support either.
check_installed_version() {
    read_installed
    [ -n "$INSTALLED_VERSION" ] || return 0

    [ "${INSTALLED_VERSION%%.*}" = "$OPENSEARCH_MAJOR" ] \
        || die "OpenSearch ${INSTALLED_VERSION} is installed and this script pins ${OPENSEARCH_VERSION}, another major version. That upgrade cannot be undone, so this does not make it; change the pin to a ${INSTALLED_VERSION%%.*}.x release to keep this host where it is."
    ! dpkg --compare-versions "$INSTALLED_VERSION" gt "$OPENSEARCH_VERSION" \
        || die "OpenSearch ${INSTALLED_VERSION} is installed, newer than the ${OPENSEARCH_VERSION} this script pins, and OpenSearch cannot go back. Raise the pin to ${INSTALLED_VERSION} or later."
}

install_opensearch() {
    read_installed

    if [ "$INSTALLED_STATUS" = installed ] && [ "$INSTALLED_VERSION" = "$OPENSEARCH_VERSION" ]; then
        log "OpenSearch ${OPENSEARCH_VERSION} is already installed."
        hold_opensearch
        return
    fi

    if [ -n "$INSTALLED_VERSION" ]; then
        # The configuration is only rewritten after this, and a path it names that is not there
        # stops that. Found now, before the package under a running OpenSearch is replaced, rather
        # than after, with nothing left to restart it on the new one.
        resolve_paths
        log "Upgrading OpenSearch ${INSTALLED_VERSION} (${INSTALLED_STATUS}) to ${OPENSEARCH_VERSION}."
    else
        log "Installing OpenSearch ${OPENSEARCH_VERSION}."
    fi

    apt-get update -qq

    # The package refuses to configure without this, and then ignores it, because the security
    # plugin is disabled below. It is never a credential anybody uses. Held by an earlier run, so apt
    # has to be told a change to it is meant, and reinstalled where the same version was left part
    # way. opensearch.yml is one of the package's configuration files and this script rewrites it,
    # so dpkg would stop to ask which to keep: the one here is kept, and written again below.
    local reinstall=()
    [ "$INSTALLED_VERSION" != "$OPENSEARCH_VERSION" ] || reinstall=(--reinstall)
    OPENSEARCH_INITIAL_ADMIN_PASSWORD="$(head -c 32 /dev/urandom | base64)" \
        DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --allow-change-held-packages "${reinstall[@]}" \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        "opensearch=${OPENSEARCH_VERSION}"
    CHANGED=true

    hold_opensearch
}

# So an unrelated `apt-get upgrade` cannot move the instance onto an untested release. On every
# run, not only after an install: a host that already had the pinned version may not be held yet.
hold_opensearch() {
    apt-mark hold opensearch > /dev/null
}

# One instance, reachable from this host only, with the security plugin off. That combination is
# what the loader and the API both expect, and it is only safe while the bind address is local.
# The data and log paths and the heap: what the host already has, unless a flag or deploy.conf says
# otherwise. Read before anything is written, and from a configuration this script wrote as much as
# from one it did not. A path that is not there would have OpenSearch fail to start, after the
# configuration that worked has been replaced, so it stops here. Run again, it changes nothing.
resolve_paths() {
    [ -n "$OPENSEARCH_DATA_DIR" ] || OPENSEARCH_DATA_DIR="$(setting_in "$CONFIG_FILE" path.data)"
    [ -n "$OPENSEARCH_DATA_DIR" ] || OPENSEARCH_DATA_DIR=/var/lib/opensearch
    [ -n "$OPENSEARCH_LOG_DIR" ] || OPENSEARCH_LOG_DIR="$(setting_in "$CONFIG_FILE" path.logs)"
    [ -n "$OPENSEARCH_LOG_DIR" ] || OPENSEARCH_LOG_DIR=/var/log/opensearch
    if [ -z "$OPENSEARCH_HEAP" ] && [ -f "$HEAP_FILE" ]; then
        OPENSEARCH_HEAP="$(sed -n 's/^-Xmx//p' "$HEAP_FILE" | tail -n 1)"
    fi
    [ -n "$OPENSEARCH_HEAP" ] || OPENSEARCH_HEAP="$DEFAULT_HEAP"

    [ -d "$OPENSEARCH_DATA_DIR" ] || die "the data directory ${OPENSEARCH_DATA_DIR} does not exist."
    [ -d "$OPENSEARCH_LOG_DIR" ] || die "the log directory ${OPENSEARCH_LOG_DIR} does not exist."
}

# How systemd runs OpenSearch: time enough to start, and started again after a failure, crash or a
# start that ran out alike. A drop-in rather than an edit of the package's unit, so an upgrade of
# the package keeps it. It takes effect on a daemon-reload, so a host that only gains it is not
# restarted for it.
write_unit_dropin() {
    local changed_before="$CHANGED"

    mkdir -p "$(dirname "$UNIT_DROPIN")"
    write_if_changed "$UNIT_DROPIN" <<UNIT
${MARKER}
[Service]
TimeoutStartSec=${START_TIMEOUT}
Restart=on-failure
RestartSec=${RESTART_DELAY}
UNIT
    CHANGED="$changed_before"
}

write_config() {
    resolve_paths

    # The configuration the package shipped, kept once. Never one this script wrote, and never over
    # a copy that is already there.
    if [ -f "$CONFIG_FILE" ] && ! grep -qxF "$MARKER" "$CONFIG_FILE" \
        && [ ! -e "${CONFIG_FILE}.dist" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.dist"
        log "Kept the packaged configuration as ${CONFIG_FILE}.dist."
    fi

    write_if_changed "$CONFIG_FILE" <<CONFIG
${MARKER}
cluster.name: unipept
node.name: ${HOSTNAME}
network.host: ${OPENSEARCH_BIND}
http.port: ${OPENSEARCH_PORT}
path.data: ${OPENSEARCH_DATA_DIR}
path.logs: ${OPENSEARCH_LOG_DIR}
discovery.type: single-node
plugins.security.disabled: true
CONFIG

    mkdir -p "$(dirname "$HEAP_FILE")"
    write_if_changed "$HEAP_FILE" <<HEAP
${MARKER}
-Xms${OPENSEARCH_HEAP}
-Xmx${OPENSEARCH_HEAP}
HEAP

    log "Configured a single node on ${OPENSEARCH_BIND}:${OPENSEARCH_PORT} with a ${OPENSEARCH_HEAP} heap, data in ${OPENSEARCH_DATA_DIR}."
}

# Where to ask whether the instance is up: the address and port it was just configured with. A
# wildcard bind is reached through the loopback address.
ready_url() {
    local host="$OPENSEARCH_BIND"

    case "$host" in 0.0.0.0 | _local_) host=127.0.0.1 ;; esac
    echo "http://${host}:${OPENSEARCH_PORT}"
}

start_opensearch() {
    local url
    url="$(ready_url)"

    systemctl daemon-reload
    systemctl enable opensearch > /dev/null

    # A restart takes the API's protein search down while it lasts, so only when it is needed. The
    # unit is Type=notify, so this waits until OpenSearch says it has started, or START_TIMEOUT.
    if [ "$CHANGED" = true ] || ! systemctl is-active --quiet opensearch; then
        systemctl restart opensearch \
            || die "OpenSearch did not start within $((START_TIMEOUT / 60)) minutes. systemd starts it again every ${RESTART_DELAY} seconds; see: journalctl -u opensearch"
    else
        log "Nothing changed, so OpenSearch is left running."
    fi

    log "Waiting for OpenSearch to answer at ${url}."
    curl -sSf -o /dev/null --retry-all-errors --retry "$((OPENSEARCH_READY_TIMEOUT / 3))" \
        --retry-delay 3 --retry-max-time "$OPENSEARCH_READY_TIMEOUT" "${url}/_cluster/health" 2> /dev/null \
        || die "OpenSearch did not answer at ${url} within ${OPENSEARCH_READY_TIMEOUT} seconds. See: journalctl -u opensearch"

    log "OpenSearch is up."
}

# One node holds no replica, so an index that asks for one stays yellow, and cluster health then
# says nothing about whether this host is well. uniprot_entries asks for none itself; this is for
# every other index. Cluster settings, so through the API once the node is up.
#
# The default covers every index created from now on, hidden ones included, which an index
# template does not. The query insights plugin asks for a replica for its top_queries-* indices
# whatever the default says, so its exporter to a local index is turned off: the top queries stay
# available from the plugin's API, in memory. The indices already there are set to none as well.
# Measured on 2.19.0, where these leave a fresh node green.
single_node_settings() {
    local url="$1"

    curl -sSf -o /dev/null -X PUT "${url}/_cluster/settings" -H 'Content-Type: application/json' \
        -d '{"persistent":{"cluster.default_number_of_replicas":0,"search.insights.top_queries.exporter.type":"none"}}' \
        || die "could not set the cluster settings a single node needs at ${url}."
    curl -sSf -o /dev/null -X PUT "${url}/_all/_settings?expand_wildcards=all" -H 'Content-Type: application/json' \
        -d '{"index":{"number_of_replicas":0}}' \
        || die "could not remove the replicas of the indices already at ${url}."

    log "Set every index to hold no replica, as a single node has nowhere to put one."
}

parse_arguments "$@"

[ "$(id -u)" -eq 0 ] || die "run this as root. It is the only step that needs it."
checkdep apt-get
checkdep dpkg-query
checkdep dpkg
checkdep systemctl
checkdep getent
checkdep useradd
checkdep usermod
checkdep visudo "sudo"

# Before anything on the host changes, so a refused run leaves it as it was.
check_installed_version

ensure_user
install_tools
prepare_output_dir
install_scripts
allow_opensearch_restart

# Installed with the tools above.
checkdep curl
checkdep gpg

add_repository
install_opensearch
write_config
write_unit_dropin
start_opensearch
single_node_settings "$(ready_url)"

cat >&2 <<EOF

Still to do on this host:
  1. As root, say what this host decides in ${PREFIX}/etc/deploy.conf.
As ${DEPLOY_USER} (sudo -iu ${DEPLOY_USER}), none of it as root:
  2. To clone from another host: an ssh key in ~/.ssh that ${DEPLOY_USER} on that host accepts.
     ${PREFIX}/bin/clone.sh then copies a database, and ${PREFIX}/bin/load.sh loads its proteins.
  3. To build: clone unipept-database, which build.sh needs whole, and install Rust with rustup
     (https://rustup.rs); the repository pins the toolchain. .deploy/build.sh in that clone reads
     the same deploy.conf.
  4. On a host that runs the API, once: ${PREFIX}/bin/migrate.sh, which sets it up for switch.sh.
EOF
log "The host is ready."
