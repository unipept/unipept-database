#!/usr/bin/env bash
#
# Sets up the OpenSearch instance load.sh fills, on a host server/install.sh prepares: server/install.sh
# runs this, after the tools this uses are installed. Run it on its own, as root, to change a
# setting of the instance, such as its heap. Run it with --help for the options.
#
# For the Ubuntu 24.04 LTS the servers run: it installs through apt and starts through systemd.
#
# It loads nothing. load.sh does that, here and after every build.
#
# Flow:
#   1. Check that this runs as root on a host with apt and systemd, and that the OpenSearch it has,
#      if any, can be brought to the pinned version: nothing is changed on a host where not.
#      --check stops here, which is how server/install.sh asks before it changes anything.
#   2. Take the OpenSearch lock, held to the end, so no load runs while OpenSearch is upgraded or
#      restarted.
#   3. Add the OpenSearch APT repository, unless it is already there.
#   4. Install the pinned version, or upgrade an older one of the same major version to it, keeping
#      the configuration this script writes, and hold it so an unrelated upgrade cannot move it.
#   5. Write the configuration this instance needs, keeping a copy of what was there and the data
#      and log paths it named.
#   6. Write the heap size, and a systemd drop-in giving OpenSearch time to start and starting it
#      again after a failure.
#   7. Enable and start the service, restarting it only when something above changed, and wait
#      for it to answer.
#   8. Set every index to hold no replica.
#
# A second run with the same settings changes nothing and restarts nothing.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -r "${HERE}/../../lib.sh" ] || { echo "Error: there is no ${HERE}/../../lib.sh to load." 1>&2; exit 2; }
# shellcheck source=../../lib.sh
source "${HERE}/../../lib.sh"

# The settings only this script has.

# The version every host runs. Pinned, and held in apt afterwards, so a host cannot drift onto a
# release nothing has been tested against.
# shellcheck source=version.sh
source "${HERE}/version.sh"

# The heap OpenSearch takes, and the one number a host decides. Deliberately small: this host also
# serves the API, which holds the index resident, and the API's deploy sizes that against the
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

# The install server/install.sh makes, whose deploy.conf this reads too.
# shellcheck disable=SC2034 # read and set by read_install_conf
PREFIX="$INSTALL_ROOT"
read_install_conf "$@"

# Whether to only check that the OpenSearch installed can be brought to the pinned version.
CHECK_ONLY=false

# OpenSearch publishes one apt repository per major version, so the one to add follows the pin.
readonly OPENSEARCH_MAJOR="${OPENSEARCH_VERSION%%.*}"
readonly APT_LIST="/etc/apt/sources.list.d/opensearch-${OPENSEARCH_MAJOR}.x.list"
readonly APT_KEYRING=/usr/share/keyrings/opensearch-keyring.gpg
readonly CONFIG_FILE=/etc/opensearch/opensearch.yml
readonly HEAP_FILE=/etc/opensearch/jvm.options.d/heap.options
readonly UNIT_DROPIN=/etc/systemd/system/opensearch.service.d/unipept.conf

# How long systemd gives OpenSearch to start, and how soon it starts it again after a failure. The
# package gives it 75 seconds and never starts it again. That is enough on its own, but not while
# unattended upgrades restart it and are busy with the same disk: on a host whose index is not in
# the page cache, such as one running the API's preloaded variant, that start ran out every time,
# and the host was left without OpenSearch until someone noticed, for months once.
readonly START_TIMEOUT=600
readonly RESTART_DELAY=30
readonly MARKER='# Written by unipept-database .deploy/server/opensearch/install.sh. Edit that, not this.'

# Whether this run wrote a file the service reads, and so has to restart it.
CHANGED=false

usage() {
    cat <<'USAGE'
Sets up the OpenSearch instance the proteins are loaded into. .deploy/server/install.sh runs this as
part of preparing a host; run it on its own, as root, to change a setting of the instance.

  .deploy/server/opensearch/install.sh [OPTIONS]

  --heap SIZE                the heap OpenSearch takes, for example 8g; default what the host has,
                             or 4g
  --bind ADDRESS             the address it listens on
  --port PORT                the port it listens on
  --data-dir DIR             where it keeps its data; default what the configuration names
  --log-dir DIR              where it writes its logs; default what the configuration names
  --prefix DIR               the install whose deploy.conf is read, default /opt/unipept-database
  --check                    only check that the OpenSearch installed can be brought to the pinned
                             version, and change nothing
  --help                     print this message

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
            --prefix) need_value "$1" "${2-}"; shift 2 ;;
            --check) CHECK_ONLY=true; shift ;;
            --help) usage; exit 0 ;;
            *) unknown_option "$1" ;;
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

[ "$(id -u)" -eq 0 ] || die "run this as root. It is one of the two steps that need it."
require apt-get dpkg-query dpkg systemctl

# Before anything on the host changes, so a refused run leaves it as it was.
check_installed_version
[ "$CHECK_ONLY" = false ] || exit 0

# A load writes to OpenSearch for hours, and the upgrade and the restart below would break it part
# way. Held from here to the end, as a switch holds it; where server/install.sh runs this, taken
# over from it on the descriptor this inherits.
require flock:util-linux
take_opensearch_lock -x || die "$(lock_refused $?) Set up OpenSearch once it has finished."

# Installed with the tools above.
require curl gpg

add_repository
install_opensearch
write_config
write_unit_dropin
start_opensearch
single_node_settings "$(ready_url)"

log "OpenSearch is ready."
