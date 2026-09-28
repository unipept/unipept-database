#!/usr/bin/env bash
#
# Puts one database on every API server: copies it from the host that has it to each server that
# does not, and loads its proteins into each server's OpenSearch. Run it with --help for the
# options.
#
# Nothing it does changes what the API serves. The copy lands beside the database a server uses, and
# the load goes into an index of that version beside the one the API queries, so every server stays
# in rotation throughout. Switching the API to the new version is the API's rollout.
#
# It never builds. The version has to be whole on the source host already: build it there with
# build.sh, and run this once it has finished.
#
# Flow:
#   1. Read servers.conf, and check the source: it answers, and its copy of the version passes
#      verify.sh there. Where it does not, stop, and say to build it there.
#   2. Check every server before any is touched: it answers, and has a checkout with the scripts.
#   3. Per server, in the order of servers.conf:
#        the files: verify.sh there. Missing, clone.sh copies them from the source. There but
#        failing, the server is left alone unless --replace says to copy them again.
#        the proteins: load.sh --check there. Not loaded to the end, load.sh loads them.
#      A server that fails is reported, and the next one is still attempted.
#   4. A table of what each server had, what was done, and whether it is ready.
#
# The copy and the load take hours over one ssh session per step. Run it in tmux or screen, so a
# dropped connection on this side does not end them; a rerun picks up where it stopped.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

# The servers to put the database on.
SERVERS_FILE="${HERE}/servers.conf"

# Who to log in as on the source and the servers: the user who owns the databases there.
SSH_USER="$DEPLOY_USER"

read_conf

# The settings only this script has. After read_conf rather than before: a UNIPROT_VERSION in
# deploy.conf is the release clone.sh on this host fetches, not the one to distribute.

# The version to put on every server. Required.
UNIPROT_VERSION=

# The host that has it, and where unipept-database is cloned there.
SOURCE=
# shellcheck disable=SC2088 # expanded on the source, where that user's home is
SOURCE_CHECKOUT='~/unipept-database'

# Whether a server whose copy of the version fails verification gets a new one.
REPLACE=false

usage() {
    cat <<'USAGE'
Copies a database to every API server that lacks it and loads its proteins there, without changing
what any of them serves.

  .deploy/distribute.sh --uniprot-version YYYY-MM --from HOST [OPTIONS]

  --uniprot-version YYYY-MM  the version to distribute, required
  --from HOST              the host that has it, required. It is not built here
  --from-checkout DIR      where unipept-database is cloned on that host, default ~/unipept-database
  --servers FILE           the servers to put it on, default .deploy/servers.conf
  --ssh-user USER          who to log in as, default the user that owns the databases
  --replace                copy again to a server whose copy fails verification
  --help                   print this message

Exits 0 when every server has the version and its proteins loaded, 1 when any does not, and 2 when
it stopped before touching a server.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uniprot-version) need_value "$1" "${2-}"; UNIPROT_VERSION="$2"; shift 2 ;;
            --from) need_value "$1" "${2-}"; SOURCE="$2"; shift 2 ;;
            --from-checkout) need_value "$1" "${2-}"; SOURCE_CHECKOUT="$2"; shift 2 ;;
            --servers) need_value "$1" "${2-}"; SERVERS_FILE="$2"; shift 2 ;;
            --ssh-user) need_value "$1" "${2-}"; SSH_USER="$2"; shift 2 ;;
            --replace) REPLACE=true; shift ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    [ -n "$UNIPROT_VERSION" ] || die "--uniprot-version is required."
    [[ "$UNIPROT_VERSION" =~ ^[0-9]{4}-[0-9]{2}$ ]] || die "--uniprot-version takes YYYY-MM, not '${UNIPROT_VERSION}'."
    [ -n "$SOURCE" ] || die "--from is required: the host that has ${UNIPROT_VERSION}. This script does not build."
    valid_checkout "$SOURCE_CHECKOUT" || die "--from-checkout takes a path of letters, digits and ~ . _ - /, not '${SOURCE_CHECKOUT}'."
}

# A checkout path goes into a remote shell unquoted, so that ~ expands there, which it can only do
# safely when it holds nothing else a shell reads.
valid_checkout() {
    [[ "$1" =~ ^[~A-Za-z0-9_./-]+$ ]]
}

# Runs a command in a checkout on a host, as SSH_USER. Each argument is quoted for the remote shell,
# since some come from another host. BatchMode, so a host that asks for a password fails at once
# rather than waiting; keepalives, so an idle hour of loading is not taken for a dead connection.
on() {
    local host="$1" checkout="$2" command
    shift 2
    command=$(printf '%q ' "$@")

    ssh -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=5 \
        "${SSH_USER}@${host}" "cd ${checkout} && ${command}" < /dev/null
}

# The servers, one "name host checkout" line each, with what servers.conf gets wrong refused.
read_servers() {
    local name host checkout seen=' '

    [ -f "$SERVERS_FILE" ] || die "there is no ${SERVERS_FILE}. Copy servers.conf.example beside it and fill it in."

    while read -r name host checkout _; do
        case "${name:-}" in '' | \#*) continue ;; esac
        [ -n "$checkout" ] || die "the line for '${name}' in ${SERVERS_FILE} has too few fields."
        valid_checkout "$checkout" || die "the checkout of '${name}' takes a path of letters, digits and ~ . _ - /, not '${checkout}'."
        [[ "$seen" != *" ${name} "* ]] || die "'${name}' is in ${SERVERS_FILE} twice."
        seen+="${name} "
        printf '%s %s %s\n' "$name" "$host" "$checkout"
    done < "$SERVERS_FILE"
}

# The directory the source keeps its databases in, from what verify.sh there says it checked. The
# source's own deploy.conf decides it, so this is the one place that knows.
check_source() {
    local output

    # To stderr, like everything else here that is not the answer, which the caller captures.
    log "Checking ${UNIPROT_VERSION} on ${SOURCE}." 1>&2
    output=$(on "$SOURCE" "$SOURCE_CHECKOUT" .deploy/verify.sh --uniprot-version "$UNIPROT_VERSION" 2>&1) || {
        printf '%s\n' "$output" | sed 's/^/  /' 1>&2
        die "${SOURCE} does not have a whole ${UNIPROT_VERSION}. Build it there with .deploy/build.sh first; this script does not build."
    }

    output=$(printf '%s\n' "$output" | sed -n 's/^Checking \(.*\)\/uniprot-[0-9-]*\/suffix-array$/\1/p')
    [ -n "$output" ] || die "could not tell where ${SOURCE} keeps its databases from what verify.sh said."
    echo "$output"
}

# Every server answers and has the scripts, before any of them is touched.
check_servers() {
    local name host checkout unready=''

    while read -r name host checkout; do
        on "$host" "$checkout" test -x .deploy/verify.sh -a -x .deploy/clone.sh -a -x .deploy/load.sh 2> /dev/null \
            || unready+=" ${name}"
    done <<< "$SERVERS"

    [ -z "$unready" ] || die "cannot reach, or find unipept-database at its checkout on:${unready}. Nothing was changed."
}

# Puts the version on one server, and prints what it found and did as files|proteins|result.
distribute_to() {
    local name="$1" host="$2" checkout="$3" files proteins clone_arguments verified

    if verified=$(on "$host" "$checkout" .deploy/verify.sh --uniprot-version "$UNIPROT_VERSION" 2>&1); then
        files=had
    else
        clone_arguments=(--remote-address "$SOURCE" --remote-output-dir "$SOURCE_OUTPUT_DIR" --uniprot-version "$UNIPROT_VERSION")

        # verify.sh fails alike for a copy that is not there and one that is broken. Only the first
        # is copied without being asked: the second may be what someone is looking into.
        if ! grep -q 'is not a directory' <<< "$verified"; then
            if [ "$REPLACE" != true ]; then
                echo "broken|-|its copy fails verification; --replace copies it again"
                return
            fi
            clone_arguments+=(--replace)
        fi

        log "${name}: copying ${UNIPROT_VERSION} from ${SOURCE}." 1>&2
        if on "$host" "$checkout" .deploy/clone.sh "${clone_arguments[@]}" 1>&2; then
            files=copied
        else
            echo "failed|-|the copy failed"
            return
        fi
    fi

    if on "$host" "$checkout" .deploy/load.sh --uniprot-version "$UNIPROT_VERSION" --check > /dev/null 2>&1; then
        proteins=had
    else
        log "${name}: loading the proteins of ${UNIPROT_VERSION}." 1>&2
        if on "$host" "$checkout" .deploy/load.sh --uniprot-version "$UNIPROT_VERSION" 1>&2; then
            proteins=loaded
        else
            echo "${files}|failed|the load failed"
            return
        fi
    fi

    echo "${files}|${proteins}|ready"
}

parse_arguments "$@"

SERVERS=$(read_servers)
[ -n "$SERVERS" ] || die "${SERVERS_FILE} lists no server."

SOURCE_OUTPUT_DIR=$(check_source)
check_servers

results=''
failed=0
while read -r name host checkout; do
    result=$(distribute_to "$name" "$host" "$checkout")
    results+="${name}|${result}"$'\n'
    [[ "$result" == *"|ready" ]] || failed=1
done <<< "$SERVERS"

echo
printf '%-12s %-8s %-9s %s\n' SERVER FILES PROTEINS RESULT
while IFS='|' read -r name files proteins result; do
    [ -n "$name" ] || continue
    printf '%-12s %-8s %-9s %s\n' "$name" "$files" "$proteins" "$result"
done <<< "$results"

if [ "$failed" -eq 0 ]; then
    log "Every server has ${UNIPROT_VERSION}, with its proteins loaded. Switch the API to it with its rollout."
else
    log "Not every server is ready; the table says which, and the output above says why. A rerun picks up where this stopped."
fi
exit "$failed"
