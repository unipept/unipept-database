#!/usr/bin/env bash
#
# .deploy/build.sh and .deploy/clone.sh, in a container that has what a host has. The cases run
# inside it: they start an sshd and clone over it, so the copy goes through a real scp.
#
# Needs Docker. Nothing is published on the host.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

readonly IMAGE=unipept-deploy-test

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

require_docker

# CI builds the image beforehand through a layer cache, and says so.
if [ "${DEPLOY_TEST_IMAGE_BUILT:-}" != true ]; then
    heading "Building the deploy test image"
    # Without -e, a failed build would otherwise go on to run the cases in whatever image was built
    # before, and pass against it.
    docker build -q -t "$IMAGE" "$HERE" > /dev/null || { echo "the deploy test image did not build" >&2; exit 1; }
fi

heading "Deploy suite: build.sh and clone.sh"
docker run --rm -v "${REPO}:/repo:ro" "$IMAGE" bash /repo/tests/deploy/cases.sh
