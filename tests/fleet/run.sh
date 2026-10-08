#!/usr/bin/env bash
#
# Rehearses a release on a fleet in containers: a build host, two API servers and a load balancer,
# taken through the release runbook with this checkout's scripts and the latest release of the API,
# its scripts and its binary. Nothing is stood in for but the data, which is the seam suite's
# fixtures. See README.md beside this file.
#
#   tests/fleet/run.sh
#
# Needs Docker on x86_64, where the API's release binaries run, and vm.max_map_count of at least
# 262144 on the Docker host, below which OpenSearch does not start. FLEET_LOGS names a directory to
# keep every host's logs in; FLEET_KEEP=1 leaves the containers running afterwards.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# check, check_true, check_absent, section and summary.
# shellcheck source=../assertions.sh
source "${HERE}/../assertions.sh"

readonly IMAGE=unipept-fleet-host
readonly NETWORK=unipept-fleet
readonly HOSTS=(build s1 s2 lb)
readonly SERVERS=(s1 s2)
readonly TARGET=all_handlers,db_handlers

# The UniProtKB versions the two builds are made as: the fixture metalink's, and the one after it.
readonly FIRST_DB=2026-09
readonly SECOND_DB=2026-10

WORK="$(mktemp -d)"
LOGS="${FLEET_LOGS:-${WORK}/logs}"
mkdir -p "$LOGS"

die() { echo "Error: $*" 1>&2; exit 2; }

# A command on a host, as root.
on() {
    local host=$1
    shift
    docker exec "fleet-${host}" "$@"
}

# A command line on a host, as unipept in a login shell, as an operator who logged in would run it.
as_unipept() {
    docker exec "fleet-${1}" runuser -l unipept -c "$2"
}

# Runs a step's command, its output in its own log, and prints the log's end where it fails.
logged() {
    local name=$1 status
    shift
    "$@" > "${LOGS}/${name}.log" 2>&1
    status=$?
    [ "$status" -eq 0 ] || { echo "--- ${name}.log, the end:"; tail -n 30 "${LOGS}/${name}.log"; }
    return "$status"
}

# The API's releases from 2.7.0, newest first, as tags: the first with the deploy flow this
# repository's scripts read.
api_releases() {
    curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
        "https://api.github.com/repos/unipept/unipept-api/releases?per_page=30" \
        | python3 -c '
import json, sys
for release in json.load(sys.stdin):
    tag = release["tag_name"]
    numbers = tuple(int(part) for part in tag.lstrip("v").split("."))
    if not release["draft"] and not release["prerelease"] and numbers >= (2, 7, 0):
        print(tag)'
}

# What each host logged, kept for whoever reads a failure, and the fleet removed.
teardown() {
    local host
    for host in "${HOSTS[@]}"; do
        on "$host" journalctl --no-pager -n 300 > "${LOGS}/journal-${host}.log" 2>&1
        on "$host" runuser -u unipept -- env XDG_RUNTIME_DIR=/run/user/"$(on "$host" id -u unipept 2> /dev/null)" \
            journalctl --user --no-pager -n 200 > "${LOGS}/journal-${host}-unipept.log" 2>&1
    done
    on lb cat /var/log/fleet-poller.log > "${LOGS}/poller.log" 2>&1
    if [ "${FLEET_KEEP:-}" != 1 ]; then
        for host in "${HOSTS[@]}"; do docker rm -f "fleet-${host}" > /dev/null 2>&1; done
        docker network rm "$NETWORK" > /dev/null 2>&1
    fi
    [ -n "${FLEET_LOGS:-}" ] || echo "Logs: ${LOGS}"
}

# The requests the poller sent since a mark that did not answer 200.
failed_requests_since() {
    on lb tail -n "+$(( $1 + 1 ))" /var/log/fleet-poller.log | grep -vc ' 200$'
}

# How many requests the poller has sent, for failed_requests_since.
poller_mark() {
    on lb bash -c 'wc -l < /var/log/fleet-poller.log'
}

# The value of one key=value line of deploy.sh status on a server.
api_status() {
    as_unipept "$1" '/opt/unipept-api/deploy/server/deploy.sh status' | sed -n "s/^${2}=//p"
}


# -- 1. the fleet ---------------------------------------------------------------------------------

command -v docker > /dev/null || die "Docker is not installed."
[ "$(docker info --format '{{.Architecture}}')" = x86_64 ] \
    || die "the API's release binaries are x86_64, and this Docker runs $(docker info --format '{{.Architecture}}')."

RELEASES="$(api_releases)" || die "could not list the API's releases."
LATEST="$(sed -n 1p <<< "$RELEASES")"
[ -n "$LATEST" ] || die "the API has no release from 2.7.0 on, the first with the deploy flow these scripts read."
# The rollout goes from the release before the latest to the latest. With only one release from
# 2.7.0, it rolls the latest out over itself, which a rollout does in full.
PREVIOUS="$(sed -n 2p <<< "$RELEASES")"
PREVIOUS="${PREVIOUS:-$LATEST}"
echo "The API: ${PREVIOUS} first, then a rollout to ${LATEST}."

git clone -q --depth 1 --branch "$LATEST" https://github.com/unipept/unipept-api "${WORK}/unipept-api" \
    || die "could not clone unipept-api at ${LATEST}."

trap teardown EXIT

docker build -q -t "$IMAGE" "$HERE" > /dev/null || die "could not build the host image."
docker network create "$NETWORK" > /dev/null || die "could not create the network ${NETWORK}."
for host in "${HOSTS[@]}"; do
    docker run -d --name "fleet-${host}" --hostname "$host" --network "$NETWORK" \
        --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$IMAGE" > /dev/null \
        || die "could not start ${host}."
done
for host in "${HOSTS[@]}"; do
    for _ in $(seq 60); do
        [ "$(on "$host" systemctl is-system-running 2> /dev/null)" = running ] && break
        sleep 1
    done
done

# Both repositories on every host that installs from them, as a person copies a checkout over.
tar -C "$REPO" --exclude=./target -cf "${WORK}/unipept-database.tar" .
tar -C "${WORK}/unipept-api" --exclude=./.git -cf "${WORK}/unipept-api.tar" .
for host in "${HOSTS[@]}"; do
    on "$host" mkdir -p /src/unipept-database /src/unipept-api
    docker exec -i "fleet-${host}" tar -x -C /src/unipept-database < "${WORK}/unipept-database.tar"
    docker exec -i "fleet-${host}" tar -x -C /src/unipept-api < "${WORK}/unipept-api.tar"
done

section "1. the fleet"
for host in "${HOSTS[@]}"; do
    check "${host} has booted" "$(on "$host" systemctl is-system-running 2> /dev/null)" "running"
done


# -- 2. clean installs ----------------------------------------------------------------------------

section "2. clean installs"

for host in build s1 s2; do
    logged "install-db-${host}" on "$host" /src/unipept-database/.deploy/server/install.sh \
        --user unipept --output-dir /srv/unipept --heap 512m
    check "the database install on ${host} succeeds" "$?" "0"
    on "$host" bash -c 'printf "OUTPUT_DIR=/srv/unipept\n" > /opt/unipept-database/etc/deploy.conf'
done
for host in "${SERVERS[@]}"; do
    logged "install-api-${host}" on "$host" /src/unipept-api/.deploy/server/install.sh
    check "the API install on ${host} succeeds" "$?" "0"
done
for host in "${SERVERS[@]}"; do
    logged "reinstall-db-${host}" on "$host" /src/unipept-database/.deploy/server/install.sh \
        --user unipept --output-dir /srv/unipept --heap 512m
    check "the database install on ${host} runs again" "$?" "0"
    logged "reinstall-api-${host}" on "$host" /src/unipept-api/.deploy/server/install.sh
    check "the API install on ${host} runs again" "$?" "0"
done

# The operator on the load balancer is an account a person makes; its install refuses a host
# without it.
on lb useradd --create-home --shell /bin/bash unipept

# Keys, and ~/.ssh/config entries naming the port and the key, as a person sets them up: the load
# balancer reaches every host, each server reaches the build host.
for host in lb s1 s2; do
    as_unipept "$host" 'mkdir -p -m 700 ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
done
authorize() {
    local from=$1 to=$2
    as_unipept "$to" 'mkdir -p -m 700 ~/.ssh'
    on "$from" cat /home/unipept/.ssh/id_ed25519.pub \
        | docker exec -i "fleet-${to}" runuser -u unipept -- tee -a /home/unipept/.ssh/authorized_keys > /dev/null
    as_unipept "$from" "ssh-keyscan -p 2222 -H ${to} >> ~/.ssh/known_hosts 2> /dev/null"
    as_unipept "$from" "printf 'Host ${to}\n    Port 2222\n    IdentityFile ~/.ssh/id_ed25519\n' >> ~/.ssh/config"
}
for to in build s1 s2; do authorize lb "$to"; done
for from in "${SERVERS[@]}"; do authorize "$from" build; done

for to in build s1 s2; do
    check_true "lb reaches ${to} through ~/.ssh/config" as_unipept lb "ssh -o BatchMode=yes ${to} true"
done
for from in "${SERVERS[@]}"; do
    check_true "${from} reaches build through ~/.ssh/config" as_unipept "$from" "ssh -o BatchMode=yes build true"
done


# -- 3. and 8. the builds -------------------------------------------------------------------------

# The fixtures as the pipeline downloads them, under the version given, and a build of them. The
# build host's OpenSearch is stopped for the build, as build.sh asks, and started again after.
build_database() {
    local metalink_version=${1/-/_}

    on build systemctl stop opensearch
    as_unipept build "cd ~/unipept-database \
        && source tests/lib.sh \
        && mkdir -p ~/fixtures \
        && use_fixture_sources ~/fixtures \
        && sed 's/2026_09/${metalink_version}/' tests/pipelines/sources/RELEASE.metalink > ~/fixtures/RELEASE.metalink \
        && export UNIPEPT_RELEASE_METALINK_URL=file://\$HOME/fixtures/RELEASE.metalink \
        && .deploy/build.sh --output-dir /srv/unipept --scratch-dir ~/scratch --database-sources swissprot"
    local status=$?
    on build systemctl start opensearch
    return "$status"
}

section "3. build the first database"

on build cp -a /src/unipept-database /home/unipept/unipept-database
on build chown -R unipept: /home/unipept/unipept-database
logged rustup as_unipept build 'curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none'
check "rustup installs" "$?" "0"
logged "build-${FIRST_DB}" build_database "$FIRST_DB"
check "build.sh builds ${FIRST_DB}" "$?" "0"
check_true "verify.sh passes on it" \
    as_unipept build "/opt/unipept-database/deploy/server/verify.sh --uniprot-version ${FIRST_DB}"


# -- 4. and 8. distribution -----------------------------------------------------------------------

on lb cp -a /src/unipept-database /home/unipept/unipept-database
on lb bash -c 'printf "s1 s1\ns2 s2\n" > /home/unipept/unipept-database/.deploy/servers.conf'
on lb chown -R unipept: /home/unipept/unipept-database

distribute() {
    as_unipept lb "cd ~/unipept-database && .deploy/distribute.sh --uniprot-version $1 --from build"
}

# The row distribute.sh prints for a server.
row_says() {
    grep -qE "^$1 +$2 +$3 +$4\$" "${LOGS}/$5.log"
}

section "4. distribute it"

logged "distribute-${FIRST_DB}" distribute "$FIRST_DB"
check "distribute.sh succeeds" "$?" "0"
for host in "${SERVERS[@]}"; do
    check_true "${host} is copied to and loaded" row_says "$host" copied loaded ready "distribute-${FIRST_DB}"
done
logged "distribute-${FIRST_DB}-again" distribute "$FIRST_DB"
check "a second run succeeds" "$?" "0"
for host in "${SERVERS[@]}"; do
    check_true "and does nothing on ${host}" row_says "$host" had had ready "distribute-${FIRST_DB}-again"
done


# -- 5. the API, by hand --------------------------------------------------------------------------

section "5. the API, by hand"

for host in "${SERVERS[@]}"; do
    as_unipept "$host" "ln -s uniprot-${FIRST_DB} /srv/unipept/current"
    on "$host" sed -i \
        -e 's|^INDEX_LOCATION=.*|INDEX_LOCATION=/srv/unipept/current/suffix-array|' \
        -e 's|^DATABASE_ADDRESS=.*|DATABASE_ADDRESS=http://127.0.0.1:9200|' \
        -e 's|^VARIANT=.*|VARIANT=mmap|' \
        /opt/unipept-api/etc/unipept-api.env
    logged "deploy-${host}" as_unipept "$host" "/opt/unipept-api/deploy/server/deploy.sh deploy --version ${PREVIOUS}"
    check "deploy.sh deploys ${PREVIOUS} on ${host}" "$?" "0"
    check "${host} reports it" "$(api_status "$host" version)" "${PREVIOUS#v}"
    check "and the index the database scripts loaded" "$(api_status "$host" index_version)" "${FIRST_DB/-/.}"
    check "and answers on port 80" "$(on lb curl -s -o /dev/null -w '%{http_code}' "http://${host}/health")" "200"
done


# -- 6. the load balancer -------------------------------------------------------------------------

section "6. the load balancer"

logged haproxy-package on lb bash -c 'apt-get update -qq && apt-get install -y -qq haproxy'
check "HAProxy installs" "$?" "0"
docker cp "${HERE}/haproxy.cfg" fleet-lb:/etc/haproxy/haproxy.cfg > /dev/null
on lb systemctl restart haproxy
on lb mkdir -p /etc/unipept-rollout
on lb bash -c 'printf "s1 s1 80 all_handlers,db_handlers s1\ns2 s2 80 all_handlers,db_handlers s2\n" > /etc/unipept-rollout/servers.conf'
on lb bash -c 'printf "HAPROXY_SOCKET=/run/haproxy/admin.sock\nSSH_USER=unipept\nNOTIFY_TO=\n" > /etc/unipept-rollout/rollout.conf'

logged install-lb on lb /src/unipept-api/.deploy/loadbalancer/install.sh
check "loadbalancer/install.sh and its audit pass" "$?" "0"

# Both routes through HAProxy every half second, one line per request, from here to the end.
on lb bash -c 'touch /var/log/fleet-poller.log'
docker exec -d fleet-lb bash -c 'while :; do
    for route in pept2lca pept2prot; do
        code=$(curl -s -g -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost/api/v2/${route}.json?input[]=VALIDATEK")
        echo "$(date +%T) ${route} ${code}" >> /var/log/fleet-poller.log
    done
    sleep 0.5
done'
check_true "a fixture peptide comes back through HAProxy" \
    bash -c "docker exec fleet-lb curl -s -g 'http://localhost/api/v2/pept2prot.json?input[]=VALIDATEK' | grep -q P00002"


# -- 7. a rollout ---------------------------------------------------------------------------------

section "7. a rollout"

mark=$(poller_mark)
logged rollout as_unipept lb "/opt/unipept-rollout/rollout.sh --version ${LATEST}"
check "rollout.sh rolls out ${LATEST}" "$?" "0"
for host in "${SERVERS[@]}"; do
    check "${host} reports ${LATEST}" "$(api_status "$host" version)" "${LATEST#v}"
done
check_true "rollout.sh status reads the run back" as_unipept lb "/opt/unipept-rollout/rollout.sh status"
check "and no request failed meanwhile" "$(failed_requests_since "$mark")" "0"


# -- 8. a second database -------------------------------------------------------------------------

section "8. a second database"

logged "build-${SECOND_DB}" build_database "$SECOND_DB"
check "build.sh builds ${SECOND_DB}" "$?" "0"
logged "distribute-${SECOND_DB}" distribute "$SECOND_DB"
check "distribute.sh puts it on every server" "$?" "0"
for host in "${SERVERS[@]}"; do
    check_true "${host} is copied to and loaded" row_says "$host" copied loaded ready "distribute-${SECOND_DB}"
    check "and still serves ${FIRST_DB}" "$(api_status "$host" index_version)" "${FIRST_DB/-/.}"
done


# -- 9. the switch --------------------------------------------------------------------------------

section "9. the switch"

# Out of the pool, switched, and back, one server at a time: switch.sh knows nothing of the load
# balancer, so this is what whoever runs it does around it.
haproxy() {
    as_unipept lb "HAPROXY_SOCKET=/run/haproxy/admin.sock /opt/unipept-rollout/loadbalancer/haproxy.sh $*"
}
mark=$(poller_mark)
for host in "${SERVERS[@]}"; do
    haproxy drain "${TARGET}/${host}" > /dev/null && haproxy wait-empty "${TARGET}/${host}" 60 > /dev/null
    check "${host} leaves the pool" "$?" "0"
    logged "switch-${host}" as_unipept "$host" "/opt/unipept-database/deploy/server/switch.sh --uniprot-version ${SECOND_DB}"
    check "switch.sh switches ${host} to ${SECOND_DB}" "$?" "0"
    haproxy ready "${TARGET}/${host}" > /dev/null && haproxy wait-up "${TARGET}/${host}" 120 > /dev/null
    check "and it comes back into the pool" "$?" "0"
    check "it reports the new index" "$(api_status "$host" index_version)" "${SECOND_DB/-/.}"
done
check "no request failed meanwhile" "$(failed_requests_since "$mark")" "0"

summary
