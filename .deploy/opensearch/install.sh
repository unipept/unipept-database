#!/usr/bin/env bash
#
# Prepares a host to hold the proteins: installs OpenSearch, configures it for the one instance
# this host runs, and starts it. Run once per host, as root. Run it with --help for the options.
#
# It loads nothing. opensearch/load.sh does that, here and after every build.
#
# Flow:
#   1. Check that this runs as root on a host with apt and systemd.
#   2. Add the OpenSearch APT repository, unless it is already there.
#   3. Install the pinned version, held so an unrelated upgrade cannot move it.
#   4. Write the configuration this instance needs, keeping a copy of what was there.
#   5. Write the heap size, which is the one number a host has to decide.
#   6. Enable and start the service, and wait for it to answer.
#   7. Report what is left to do by hand.

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
# memory it can see. Heap taken here is memory that sizing does not know about.
OPENSEARCH_HEAP=4g

# What the instance binds to. The security plugin is off, so nothing authenticates a request, and
# an instance reachable from another host is an open datastore. Change this only together with
# turning the security plugin back on.
OPENSEARCH_BIND=127.0.0.1

# Seconds to wait for the service to answer after it is started.
OPENSEARCH_READY_TIMEOUT=180

read_conf

readonly APT_LIST=/etc/apt/sources.list.d/opensearch-2.x.list
readonly APT_KEYRING=/usr/share/keyrings/opensearch-keyring
readonly CONFIG_FILE=/etc/opensearch/opensearch.yml
readonly HEAP_FILE=/etc/opensearch/jvm.options.d/heap.options

usage() {
    cat <<'USAGE'
Installs and configures the OpenSearch instance this host loads its proteins into. Run as root.

  .deploy/opensearch/install.sh [OPTIONS]

  --heap SIZE              the heap OpenSearch takes, for example 8g
  --bind ADDRESS           the address it listens on
  --opensearch-url URL     the URL to wait for it on
  --help                   print this message

A flag wins over .deploy/deploy.conf, which wins over the defaults in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --heap) need_value "$1" "${2-}"; OPENSEARCH_HEAP="$2"; shift 2 ;;
            --bind) need_value "$1" "${2-}"; OPENSEARCH_BIND="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [[ "$OPENSEARCH_HEAP" =~ ^[0-9]+[mg]$ ]] \
        || die "--heap takes a size like 4g or 512m, not '${OPENSEARCH_HEAP}'."
}

add_repository() {
    if [ -f "${APT_KEYRING}.gpg" ] && [ -f "$APT_LIST" ]; then
        log "The OpenSearch repository is already configured."
        return
    fi

    log "Adding the OpenSearch repository."
    curl -sSfL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
        | gpg --dearmor --batch --yes -o "${APT_KEYRING}.gpg"
    echo "deb [signed-by=${APT_KEYRING}.gpg] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" \
        > "$APT_LIST"
}

install_opensearch() {
    local installed
    installed=$(dpkg-query --showformat='${Version}' --show opensearch 2> /dev/null) || installed=''

    if [ "$installed" = "$OPENSEARCH_VERSION" ]; then
        log "OpenSearch ${OPENSEARCH_VERSION} is already installed."
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

    # So an unrelated `apt-get upgrade` cannot move the instance onto an untested release.
    apt-mark hold opensearch > /dev/null
}

# One instance, reachable from this host only, with the security plugin off. That combination is
# what the loader and the API both expect, and it is only safe while the bind address is local.
write_config() {
    if [ -f "$CONFIG_FILE" ] && ! grep -q '^# Written by unipept-database' "$CONFIG_FILE"; then
        cp -n "$CONFIG_FILE" "${CONFIG_FILE}.dist"
        log "Kept the packaged configuration as ${CONFIG_FILE}.dist."
    fi

    cat > "$CONFIG_FILE" <<CONFIG
# Written by unipept-database .deploy/opensearch/install.sh. Edit that, not this.
cluster.name: unipept
node.name: ${HOSTNAME}
network.host: ${OPENSEARCH_BIND}
http.port: 9200
discovery.type: single-node
plugins.security.disabled: true
CONFIG

    mkdir -p "$(dirname "$HEAP_FILE")"
    cat > "$HEAP_FILE" <<HEAP
# Written by unipept-database .deploy/opensearch/install.sh. Edit that, not this.
-Xms${OPENSEARCH_HEAP}
-Xmx${OPENSEARCH_HEAP}
HEAP

    log "Configured a single node on ${OPENSEARCH_BIND} with a ${OPENSEARCH_HEAP} heap."
}

start_opensearch() {
    systemctl daemon-reload
    systemctl enable opensearch > /dev/null
    systemctl restart opensearch

    log "Waiting for OpenSearch to answer at ${OPENSEARCH_URL}."

    local waited=0
    until curl -sSf "${OPENSEARCH_URL}/_cluster/health" > /dev/null 2>&1; do
        [ "$waited" -lt "$OPENSEARCH_READY_TIMEOUT" ] \
            || die "OpenSearch did not answer within ${OPENSEARCH_READY_TIMEOUT} seconds. See: journalctl -u opensearch"
        sleep 3
        waited=$((waited + 3))
    done

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
