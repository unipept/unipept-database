# shellcheck shell=bash
#
# Where a host's own values come from, the settings more than one part reads, and the user they all
# run as. Needs DEPLOY_DIR, which .deploy/lib.sh sets, and die from core.sh. The other parts each
# hold the settings only they read, and each script adds the ones only it uses, then calls read_conf
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
DEPLOY_USER=unipept

# build.sh and clone.sh write what the API serves, so they run as the user the API reads as. Run as
# root, they leave a database owned by root: one the next run as DEPLOY_USER cannot replace, and
# one whose readability check passes only because root reads everything. verify.sh and load.sh
# write nothing there, but both check through that same readability check, so they refuse root
# for that reason alone. prune.sh removes databases, so it runs as the user who owns them.
refuse_root() {
    [ "$(id -u)" -ne 0 ] \
        || die "do not run this as root. Run it as ${DEPLOY_USER}, for example: sudo -iu ${DEPLOY_USER}. Only .deploy/opensearch/install.sh needs root."
}

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

# Reads one key out of the `key=value` lines on standard input, which is the shape the API's
# `deploy.sh status` prints. The last line of that key wins, as in an environment file.
env_value() {
    sed -n "s/^${1}=//p" | tail -1
}

# Sources DEPLOY_CONF over the defaults, where there is one.
read_conf() {
    if [ -f "$DEPLOY_CONF" ]; then
        # shellcheck source=/dev/null
        source "$DEPLOY_CONF"
    fi
}
