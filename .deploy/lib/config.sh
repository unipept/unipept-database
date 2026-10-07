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
# what makes every file a build writes one the API can read. server/install.sh creates it
# and gives it OUTPUT_DIR; after that, nothing here needs root.
DEPLOY_USER=unipept

# build.sh and clone.sh write what the API serves, so they run as the user the API reads as. Run as
# root, they leave a database owned by root: one the next run as DEPLOY_USER cannot replace, and
# one whose readability check passes only because root reads everything. verify.sh and load.sh
# write nothing there, but both check through that same readability check, so they refuse root
# for that reason alone. prune.sh removes databases, so it runs as the user who owns them.
refuse_root() {
    [ "$(id -u)" -ne 0 ] \
        || die "do not run this as root. Run it as ${DEPLOY_USER}, for example: sudo -iu ${DEPLOY_USER}. Only the installs in .deploy/server need root."
}

# Where server/install.sh installs the scripts a host runs, and their configuration, laid out as a
# checkout lays them out: deploy/ as .deploy/, beside opensearch/ and pipelines/. The build host
# still builds from a checkout, which needs the whole repository.
readonly INSTALL_ROOT=/opt/unipept-database

# What this host decides. Read after the defaults, so it wins over them, and before the arguments
# are parsed, so a flag wins over both. One file per host: a checkout's own deploy.conf where it has
# one, which is how a checkout is run on its own; the installed one in etc/ beside deploy/, as
# install.sh lays them out; and otherwise this host's installed one, so build.sh in a checkout reads
# the same settings as the scripts installed beside it.
#
# Installed, DEPLOY_DIR is the release's deploy/, ROOT/releases/ID/deploy, and etc/ is the install's,
# beside releases/; in a checkout, it is beside .deploy/.
case $DEPLOY_DIR in
    */releases/*/deploy) installed_conf="${DEPLOY_DIR%/releases/*}/etc/deploy.conf" ;;
    *) installed_conf="${DEPLOY_DIR%/*}/etc/deploy.conf" ;;
esac
DEPLOY_CONF="${DEPLOY_DIR}/deploy.conf"
if [ ! -f "$DEPLOY_CONF" ]; then
    if [ -f "$installed_conf" ]; then
        DEPLOY_CONF="$installed_conf"
    else
        DEPLOY_CONF="${INSTALL_ROOT}/etc/deploy.conf"
    fi
fi

# Reads one key out of the `key=value` lines on standard input, which is the shape the API's
# `deploy.sh status` prints. The last line of that key wins, as in an environment file.
env_value() {
    sed -n "s/^${1}=//p" | tail -1
}

# What an install reads, as root, given its arguments: PREFIX, from --prefix where they give one and
# INSTALL_ROOT otherwise, and the deploy.conf of the install under it, a checkout's own where it has
# one, as for any script, and otherwise that install's etc/deploy.conf, so --prefix reads its own
# and not /opt/unipept-database's. Found before the arguments are parsed, since read_conf comes
# first for a flag to win over it. Refused where anyone but root could write it: this sources it as
# root, and such a file would hand that user root. Then read as read_conf reads it.
read_install_conf() {
    local argument next

    PREFIX="$INSTALL_ROOT"
    for ((argument = 1; argument < $#; argument++)); do
        [ "${!argument}" != --prefix ] || { next=$((argument + 1)); PREFIX="${!next}"; }
    done
    [ -n "$PREFIX" ] || die "--prefix requires a value."
    [ -f "${DEPLOY_DIR}/deploy.conf" ] || DEPLOY_CONF="${PREFIX}/etc/deploy.conf"
    if [ "$DEPLOY_CONF" != "${DEPLOY_DIR}/deploy.conf" ] && [ -e "$DEPLOY_CONF" ]; then
        # The directory too: whoever owns it could put another file in this one's place.
        [ "$(stat -c %U "${DEPLOY_CONF%/*}")" = root ] \
            || die "${DEPLOY_CONF%/*} belongs to someone other than root, and this runs as root and reads ${DEPLOY_CONF} from it. Make it root's."
        case "$(stat -c '%U %A' "$DEPLOY_CONF")" in
            "root -rw-r--r--" | "root -rw-------" | "root -r--r--r--" | "root -r--------") ;;
            *) die "${DEPLOY_CONF} can be written by someone other than root, and this runs as root and reads it. Make it root's, mode 0644, after checking what is in it." ;;
        esac
    fi
    read_conf
}

# Sources DEPLOY_CONF over the defaults, where there is one.
read_conf() {
    if [ -f "$DEPLOY_CONF" ]; then
        # shellcheck source=/dev/null
        source "$DEPLOY_CONF"
    fi
}
