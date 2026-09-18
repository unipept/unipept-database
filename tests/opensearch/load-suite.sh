#!/usr/bin/env bash
#
# Brings up a real OpenSearch and a client that has what initialize_opensearch.sh needs, then runs
# the cases inside the client. A real instance rather than a stub, because what this script gets
# wrong is which indices it touches, and a stub is written by the same hand as the script.
#
# Needs Docker. Nothing is published on the host: both containers share a private network.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

readonly IMAGE=unipept-opensearch-test-client
readonly OPENSEARCH_IMAGE=opensearchproject/opensearch:2.19.0
readonly NETWORK=unipept-opensearch-test
readonly SERVER=unipept-opensearch-test-server

log() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v docker > /dev/null || { echo "docker is not installed" >&2; exit 1; }

cleanup() {
    docker rm -f "$SERVER" > /dev/null 2>&1
    docker network rm "$NETWORK" > /dev/null 2>&1
}
trap cleanup EXIT
cleanup

log "Building the client image"
docker build -q -t "$IMAGE" "$HERE" > /dev/null

log "Starting OpenSearch"
docker network create "$NETWORK" > /dev/null
docker run -d --name "$SERVER" --network "$NETWORK" \
    -e discovery.type=single-node \
    -e DISABLE_SECURITY_PLUGIN=true \
    -e DISABLE_INSTALL_DEMO_CONFIG=true \
    -e OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m" \
    "$OPENSEARCH_IMAGE" > /dev/null

started=$SECONDS
if ! docker run --rm --network "$NETWORK" "$IMAGE" \
        curl -s -f --retry 90 --retry-delay 2 --retry-max-time 180 --retry-all-errors \
        "http://${SERVER}:9200/_cluster/health" > /dev/null 2>&1
then
    echo "OpenSearch did not come up within $((SECONDS - started)) seconds" >&2
    docker logs "$SERVER" 2>&1 | tail -20 >&2
    exit 1
fi
log "OpenSearch came up in $((SECONDS - started)) seconds"

log "OpenSearch suite: initialize_opensearch.sh"
docker run --rm --network "$NETWORK" \
    -v "${REPO}:/repo:ro" \
    -e OPENSEARCH_URL="http://${SERVER}:9200" \
    "$IMAGE" bash /repo/tests/opensearch/cases.sh
