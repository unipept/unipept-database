# shellcheck shell=bash
#
# The settings more than one script has, and where a host's own values come from. Sourced through
# .deploy/lib.sh, which sets DEPLOY_DIR first. Each script adds the settings only it uses, and calls
# read_conf once all of them have a default.

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
# shellcheck disable=SC2034 # read by the scripts that source this file
API_BINARY=${API_BINARY:-/opt/unipept-api/bin/unipept-api}

# The first unipept-api release that queries uniprot_entries-<version>, the index of the version its
# files are from (unipept-api#286). An older one queries uniprot_entries itself, or the alias of that
# name, and needs what a host loaded before versioned indices kept.
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly API_VERSIONED_INDEX_SINCE=2.7.0

# The lock that keeps loads and switches apart. One per host, as the OpenSearch it guards is, whatever
# OUTPUT_DIR a run is given; /run/lock is there for every user to take one in.
# shellcheck disable=SC2034 # read by the scripts that source this file
OPENSEARCH_LOCK=${OPENSEARCH_LOCK:-/run/lock/unipept-opensearch.lock}

# Seconds a build or a clone waits for that lock once its work is done, rather than throw the work
# away: a switch holds it while OpenSearch starts, which takes minutes.
# shellcheck disable=SC2034 # read by the scripts that source this file
readonly LOCK_WAIT=3600

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
