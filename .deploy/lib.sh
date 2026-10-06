# shellcheck shell=bash
#
# Shared by the deploy scripts. Sourced, never run. Sourcing it sets the shell options and the traps
# every script runs with: see lib/core.sh.

# The directory of this file. Not HERE, which belongs to the script that sources it.
DEPLOY_DIR="${BASH_SOURCE[0]%/*}"

# Each part in its own file under lib/, and each says in its header what it uses of the others. They
# define functions and settings, and run nothing that needs another part while being sourced, so
# their order matters only to config.sh, which needs DEPLOY_DIR above: what every script runs on,
# the shared settings, versions and the links that name one, what a database holds, the locks, the
# options the scripts share, the requests to OpenSearch, and what is known of the API on this host.
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
# shellcheck source=lib/options.sh
source "${DEPLOY_DIR}/lib/options.sh"
# The names of the indices, and the requests to OpenSearch every script here shares.
# shellcheck source=../opensearch/lib.sh
source "${DEPLOY_DIR}/../opensearch/lib.sh"
# shellcheck source=lib/api.sh
source "${DEPLOY_DIR}/lib/api.sh"
