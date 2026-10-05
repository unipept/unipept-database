# shellcheck shell=bash
################################################################################
# Settings and helpers the scripts in .deploy share. Sourced, never run.       #
################################################################################

# The directory of this file. Not HERE, which belongs to the script that sources it.
DEPLOY_DIR="${BASH_SOURCE%/*}"

# Each part in its own file under lib/, in the order they build on each other: what every script
# runs on, the settings, versions and the links that name one, what a database holds, the locks,
# the requests to OpenSearch, and what is known of the API on this host.
# shellcheck source=lib/core.sh
source "${DEPLOY_DIR}/lib/core.sh"
# shellcheck source=lib/config.sh
source "${DEPLOY_DIR}/lib/config.sh"
# shellcheck source=lib/versions.sh
source "${DEPLOY_DIR}/lib/versions.sh"
# shellcheck source=lib/database.sh
source "${DEPLOY_DIR}/lib/database.sh"
# shellcheck source=lib/locks.sh
source "${DEPLOY_DIR}/lib/locks.sh"
# The names of the indices, and the requests to OpenSearch every script here shares.
# shellcheck source=../opensearch/lib.sh
source "${DEPLOY_DIR}/../opensearch/lib.sh"
# shellcheck source=lib/api.sh
source "${DEPLOY_DIR}/lib/api.sh"
