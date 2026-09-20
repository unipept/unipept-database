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

log() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v docker > /dev/null || { echo "docker is not installed" >&2; exit 1; }
docker info > /dev/null 2>&1 || { echo "the Docker daemon is not running" >&2; exit 1; }

log "Building the deploy test image"
docker build -q -t "$IMAGE" "$HERE" > /dev/null

log "Deploy suite: build.sh and clone.sh"
docker run --rm -v "${REPO}:/repo:ro" "$IMAGE" bash /repo/tests/deploy/cases.sh
