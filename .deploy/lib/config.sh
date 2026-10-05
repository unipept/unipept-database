# shellcheck shell=bash
#
# Where a host's own values come from, and the settings more than one part reads. Needs
# DEPLOY_DIR, which .deploy/lib.sh sets. The other parts each hold the settings only they read, and
# each script adds the ones only it uses, then calls read_conf once all of them have a default.

# Where the finished databases are written, one directory per UniProtKB version.
# shellcheck disable=SC2034 # read by the scripts that source this file
OUTPUT_DIR=/mnt/data

# The OpenSearch instance load.sh fills and prune.sh removes from.
# shellcheck disable=SC2034 # read by the scripts that source this file
OPENSEARCH_URL=http://localhost:9200

# Where opensearch/install.sh installs the scripts a host runs, and their configuration. The build
# host still builds from a checkout, which needs the whole repository.
readonly INSTALL_ROOT=/opt/unipept-database

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
