#! /usr/bin/env bash

set -eo pipefail

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

# This script expects an OpenSearch instance to be active on this machine. It will then drop all existing indices,
# recreate them according to the current versions of these indices and then import all proteins.


