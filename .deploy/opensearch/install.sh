#!/usr/bin/env bash
#
# Prepares a host to hold the proteins: installs OpenSearch, configures it for the one instance
# this host runs, and starts it. Run once per host, as root. Run it with --help for the options.
#
# For the Ubuntu 24.04 LTS the servers run: it installs through apt and starts through systemd.
#
# It loads nothing. opensearch/load.sh does that, here and after every build.
#
# Flow:
#   1. Check that this runs as root on a host with apt and systemd.
#   2. Add the OpenSearch APT repository, unless it is already there.
#   3. Install the pinned version, and hold it so an unrelated upgrade cannot move it.
#   4. Write the configuration this instance needs, keeping a copy of what was there and the data
#      and log paths it named.
#   5. Write the heap size, which is the one number a host has to decide.
#   6. Enable and start the service, restarting it only when something above changed, and wait
#      for it to answer.
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
# release nothing has been tested against. tests/opensearch/load-suite.sh runs the same one.
OPENSEARCH_VERSION=2.19.0

# The heap OpenSearch takes, and the one number a host decides. Deliberately small: this host also
# serves the API, which holds the index resident, and unipept-api/.deploy sizes that against the
# memory it can see. Heap taken here is memory that sizing does not know about. Empty keeps what
# the host already has, and a host that has nothing gets DEFAULT_HEAP, so a rerun without --heap
# does not undo the one it was provisioned with.
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

read_conf

readonly APT_LIST=/etc/apt/sources.list.d/opensearch-2.x.list
readonly APT_KEYRING=/usr/share/keyrings/opensearch-keyring.gpg
readonly CONFIG_FILE=/etc/opensearch/opensearch.yml
readonly HEAP_FILE=/etc/opensearch/jvm.options.d/heap.options
readonly MARKER='# Written by unipept-database .deploy/opensearch/install.sh. Edit that, not this.'

# Whether this run wrote a file the service reads, and so has to restart it.
CHANGED=false

usage() {
    cat <<'USAGE'
Installs and configures the OpenSearch instance this host loads its proteins into. Run as root.

  .deploy/opensearch/install.sh [OPTIONS]

  --heap SIZE              the heap OpenSearch takes, for example 8g; default what the host has,
                           or 4g
  --bind ADDRESS           the address it listens on
  --port PORT              the port it listens on
  --data-dir DIR           where it keeps its data; default what the configuration names
  --log-dir DIR            where it writes its logs; default what the configuration names
  --help                   print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in this script.
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

add_repository() {
    if [ -f "$APT_KEYRING" ] && [ -f "$APT_LIST" ]; then
        log "The OpenSearch repository is already configured."
        return
    fi

    log "Adding the OpenSearch repository."
    curl -sSfL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
        | gpg --dearmor --batch --yes -o "$APT_KEYRING"
    echo "deb [signed-by=${APT_KEYRING}] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" \
        > "$APT_LIST"
}

install_opensearch() {
    local status installed

    # A package that was removed but not purged still has a version, so the status decides whether
    # it is installed, not whether a version comes back.
    read -r status installed < <(dpkg-query --showformat='${db:Status-Status} ${Version}' \
        --show opensearch 2> /dev/null) || true
    [ "$status" = installed ] || installed=''

    if [ "$installed" = "$OPENSEARCH_VERSION" ]; then
        log "OpenSearch ${OPENSEARCH_VERSION} is already installed."
        hold_opensearch
        return
    fi
    [ -z "$installed" ] || die "OpenSearch ${installed} is installed and this script pins ${OPENSEARCH_VERSION}. Remove it or change the pin."

    apt-get update -qq

    # The package refuses to configure without this, and then ignores it, because the security
    # plugin is disabled below. It is never a credential anybody uses.
    log "Installing OpenSearch ${OPENSEARCH_VERSION}."
    OPENSEARCH_INITIAL_ADMIN_PASSWORD="$(head -c 32 /dev/urandom | base64)" \
        DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq "opensearch=${OPENSEARCH_VERSION}"
    CHANGED=true

    hold_opensearch
}

# So an unrelated `apt-get upgrade` cannot move the instance onto an untested release. On every
# run, not only after an install: a host that already had the pinned version was never held.
hold_opensearch() {
    apt-mark hold opensearch > /dev/null
}

# One instance, reachable from this host only, with the security plugin off. That combination is
# what the loader and the API both expect, and it is only safe while the bind address is local.
write_config() {
    # What the host already has, unless a flag or deploy.conf says otherwise. Read before anything
    # is written, and from a configuration this script wrote as much as from one it did not.
    [ -n "$OPENSEARCH_DATA_DIR" ] || OPENSEARCH_DATA_DIR="$(setting_in "$CONFIG_FILE" path.data)"
    [ -n "$OPENSEARCH_DATA_DIR" ] || OPENSEARCH_DATA_DIR=/var/lib/opensearch
    [ -n "$OPENSEARCH_LOG_DIR" ] || OPENSEARCH_LOG_DIR="$(setting_in "$CONFIG_FILE" path.logs)"
    [ -n "$OPENSEARCH_LOG_DIR" ] || OPENSEARCH_LOG_DIR=/var/log/opensearch
    if [ -z "$OPENSEARCH_HEAP" ] && [ -f "$HEAP_FILE" ]; then
        OPENSEARCH_HEAP="$(sed -n 's/^-Xmx//p' "$HEAP_FILE" | tail -n 1)"
    fi
    [ -n "$OPENSEARCH_HEAP" ] || OPENSEARCH_HEAP="$DEFAULT_HEAP"

    # A path that is not there would have OpenSearch fail to start, after the configuration that
    # worked has been replaced.
    [ -d "$OPENSEARCH_DATA_DIR" ] || die "the data directory ${OPENSEARCH_DATA_DIR} does not exist."
    [ -d "$OPENSEARCH_LOG_DIR" ] || die "the log directory ${OPENSEARCH_LOG_DIR} does not exist."

    # Explicitly rather than with cp -n, which coreutils 9.4 on Ubuntu 24.04 warns about on every
    # run, and which says nothing about whether it copied.
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

    # A restart takes the API's protein search down while it lasts, so only when it is needed.
    if [ "$CHANGED" = true ] || ! systemctl is-active --quiet opensearch; then
        systemctl restart opensearch
    else
        log "Nothing changed, so OpenSearch is left running."
    fi

    log "Waiting for OpenSearch to answer at ${url}."
    curl -sSf -o /dev/null --retry-all-errors --retry "$((OPENSEARCH_READY_TIMEOUT / 3))" \
        --retry-delay 3 --retry-max-time "$OPENSEARCH_READY_TIMEOUT" "${url}/_cluster/health" 2> /dev/null \
        || die "OpenSearch did not answer at ${url} within ${OPENSEARCH_READY_TIMEOUT} seconds. See: journalctl -u opensearch"

    log "OpenSearch is up."
}

parse_arguments "$@"

[ "$(id -u)" -eq 0 ] || die "run this as root. It is the only step that needs it."
checkdep apt-get
checkdep dpkg-query
checkdep systemctl
checkdep curl
checkdep gpg

add_repository
install_opensearch
write_config
start_opensearch

log "The host is ready. Load the proteins with opensearch/load.sh, or let .deploy/build.sh do it."
