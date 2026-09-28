# shellcheck shell=bash
#
# The OpenSearch version every host runs, and the one tests/opensearch/load-suite.sh tests the
# loader against. One place, so the two cannot drift apart. Sourced, never run.

# shellcheck disable=SC2034 # read by the scripts that source this file
OPENSEARCH_VERSION=2.19.0
