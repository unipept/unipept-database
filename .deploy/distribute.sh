#!/usr/bin/env bash
#
# Puts one database on every API server: copies it from the host that has it to each server that
# does not, and loads its proteins into each server's OpenSearch. Run it with --help for the
# options.
#
# Nothing it does changes what the API serves. The copy lands beside the database a server uses, and
# the load goes into an index of that version beside the one the API queries, so every server stays
# in rotation throughout. switch.sh on each server switches the API to the new version.
#
# It never builds. The version has to be whole on the source host already: build it there with
# build.sh, and run this once it has finished.
#
# Flow:
#   1. Read servers.conf, and check the source: it answers, and its copy of the version passes
#      verify.sh there. Where it does not, stop, and say to build it there.
#   2. Check every server before any is touched: it answers, has the scripts installed, and, where
#      it needs a copy, can make one: clone.sh --check there, with its own deploy.conf.
#   3. Per server, in the order of servers.conf:
#        the files: verify.sh there. Missing, clone.sh copies them from the source. There but
#        failing, the server is left alone unless --replace says to copy them again.
#        the proteins: load.sh --check there. Not loaded to the end, load.sh loads them. Where it
#        cannot tell, as when its OpenSearch does not say, the server is failed and not loaded.
#      A server that fails is reported, and the next one is still attempted.
#   4. A table of what each server had, what was done, and whether it is ready.
#
# The copy and the load take hours over one ssh session per step. Run it in tmux or screen, so a
# dropped connection on this side does not end them; a rerun picks up where it stopped.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -r "${HERE}/lib.sh" ] || { echo "Error: there is no ${HERE}/lib.sh to load." 1>&2; exit 2; }
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# The servers to put the database on.
SERVERS_FILE="${HERE}/servers.conf"

# Who to log in as on the source and the servers, as the API's rollout does. The port and the
# key are ssh's own to decide, from ~/.ssh/config on the machine this runs on, so a host reached on
# another port says so there once, for this and the API's rollout alike. Empty leaves the user to
# ~/.ssh/config as well. How each server reaches the source is another connection, which its own
# ~/.ssh/config decides for its clone.sh.
SSH_USER="$DEPLOY_USER"

read_conf

# The settings only this script has. After read_conf rather than before: a UNIPROT_VERSION in
# deploy.conf is the release clone.sh on this host fetches, not the one to distribute.

# The version to put on every server. Required.
UNIPROT_VERSION=

# The host that has it. Its scripts are installed where install.sh puts them, as on every host.
SOURCE=

# Whether a server whose copy of the version fails verification gets a new one.
REPLACE=false

usage() {
    cat <<'USAGE'
Copies a database to every API server that lacks it and loads its proteins there, without changing
what any of them serves.

  .deploy/distribute.sh --uniprot-version YYYY-MM --from HOST [OPTIONS]

  --uniprot-version YYYY-MM  the version to distribute, required
  --from HOST                the host that has it, required. It is not built here
  --servers FILE             the servers to put it on, default .deploy/servers.conf
  --ssh-user USER            who to log in as on the source and the servers; the port and key are
                             ~/.ssh/config's
  --replace                  copy again to a server whose copy fails verification
  --help                     print this message

Exits 0 when every server has the version and its proteins loaded, 1 when any does not, and 2 when
it stopped before touching a server.

A flag wins over .deploy/deploy.conf, which wins over the defaults in lib/ and in this script.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uniprot-version) need_value "$1" "${2-}"; valid_version "$2"; UNIPROT_VERSION="$2"; shift 2 ;;
            --from) need_value "$1" "${2-}"; SOURCE="$2"; shift 2 ;;
            --servers) need_value "$1" "${2-}"; SERVERS_FILE="$2"; shift 2 ;;
            --ssh-user) need_value "$1" "${2-}"; SSH_USER="$2"; shift 2 ;;
            --replace) REPLACE=true; shift ;;
            --help) usage; exit 0 ;;
            *) unknown_option "$1" ;;
        esac
    done

    [ -n "$UNIPROT_VERSION" ] || die "--uniprot-version is required."
    [ -n "$SOURCE" ] || die "--from is required: the host that has ${UNIPROT_VERSION}. This script does not build."
}

# Where a host's scripts are installed goes into a remote shell unquoted, which is only safe when it
# holds nothing a shell reads.
valid_root() {
    [[ "$1" =~ ^/[A-Za-z0-9_./-]*$ ]]
}

# Runs one of the installed scripts, or a command, in a host's install root, as SSH_USER. Each
# argument is quoted for the remote shell, since some come from another host.
on() {
    local host="$1" root="$2" command
    shift 2
    command=$(printf '%q ' "$@")

    # shellcheck disable=SC2029  # the command is built here on purpose, not on the host.
    ssh "${SSH_CONNECTION_BOUNDS[@]}" "${SSH_USER:+${SSH_USER}@}${host}" "cd ${root} && ${command}" < /dev/null
}

# The servers, one "name host root" line each, with what servers.conf gets wrong refused. The root is
# optional, for a server whose scripts are installed somewhere other than INSTALL_ROOT.
read_servers() {
    local name host root seen=' '

    [ -f "$SERVERS_FILE" ] || die "there is no ${SERVERS_FILE}. Copy servers.conf.example beside it and fill it in."

    while read -r name host root _; do
        case "${name:-}" in '' | \#*) continue ;; esac
        [ -n "$host" ] || die "the line for '${name}' in ${SERVERS_FILE} has no host."
        root=${root:-$INSTALL_ROOT}
        valid_root "$root" || die "the install root of '${name}' takes an absolute path of letters, digits and . _ - /, not '${root}'."
        [[ "$seen" != *" ${name} "* ]] || die "'${name}' is in ${SERVERS_FILE} twice."
        seen+="${name} "
        printf '%s %s %s\n' "$name" "$host" "$root"
    done < "$SERVERS_FILE"
}

# The directory the source keeps its databases in, from what verify.sh there says it checked. The
# source's own deploy.conf decides it, so this is the one place that knows. Stops where the source
# does not hold the version whole, which is what verify.sh is asked first.
source_output_dir() {
    local output

    # To stderr, like everything else here that is not the answer, which the caller captures.
    log "Checking ${UNIPROT_VERSION} on ${SOURCE}." 1>&2
    output=$(on "$SOURCE" "$INSTALL_ROOT" deploy/server/verify.sh --uniprot-version "$UNIPROT_VERSION" 2>&1) || {
        printf '%s\n' "$output" | sed 's/^/  /' 1>&2
        die "${SOURCE} does not have a whole ${UNIPROT_VERSION}. Build it there with .deploy/build.sh first; this script does not build."
    }

    output=$(printf '%s\n' "$output" | sed -n 's/^Checking \(.*\)\/uniprot-[0-9-]*\/suffix-array$/\1/p')
    [ -n "$output" ] || die "could not tell where ${SOURCE} keeps its databases from what verify.sh said."
    echo "$output"
}

# name -> had, missing or broken: what each server holds of the version, read in the preflight.
declare -A FILES_OF=()

# Every server, before any is touched: it answers, it has the scripts, what it holds of the version,
# and for one that needs a copy, that its clone.sh could make one from the source, which is what
# its own deploy.conf decides and what would otherwise fail only after the servers before it had
# spent hours. verify.sh answers 3 for a version that is not there at all and 1 for one that is
# there and is not whole; ssh answers 255 for a host it could not reach.
preflight_servers() {
    local name host root status problems=0

    while read -r name host root; do
        check_server_scripts "$name" "$host" "$root" || { problems=$((problems + 1)); continue; }

        status=0
        on "$host" "$root" deploy/server/verify.sh --uniprot-version "$UNIPROT_VERSION" > /dev/null 2>&1 || status=$?
        case "$status" in
            0) FILES_OF[$name]=had; continue ;;
            3) FILES_OF[$name]=missing ;;
            255) echo "FAIL ${name} cannot be reached." 1>&2; problems=$((problems + 1)); continue ;;
            *) FILES_OF[$name]=broken ;;
        esac

        # A broken copy is only copied again when --replace says so, so only then does it matter
        # whether it could be.
        [ "${FILES_OF[$name]}" = missing ] || [ "$REPLACE" = true ] || continue
        check_server_can_clone "$name" "$host" "$root" || problems=$((problems + 1))
    done <<< "$SERVERS"

    [ "$problems" -eq 0 ] || die "${problems} problem(s), so nothing was changed."
}

# Puts the version on one server, and prints what it found and did as files|proteins|result.
distribute_to() {
    local name="$1" host="$2" root="$3" files proteins status
    local clone_arguments=(--remote-address "$SOURCE" --remote-output-dir "$SOURCE_OUTPUT_DIR" --uniprot-version "$UNIPROT_VERSION")

    case "${FILES_OF[$name]}" in
        had) files=had ;;
        broken)
            # Only copied again when asked: it may be what someone is looking into.
            if [ "$REPLACE" != true ]; then
                echo "broken|-|its copy fails verification; --replace copies it again"
                return
            fi
            clone_arguments+=(--replace) ;;
    esac

    if [ "${FILES_OF[$name]}" != had ]; then
        log "${name}: copying ${UNIPROT_VERSION} from ${SOURCE}." 1>&2
        if on "$host" "$root" deploy/server/clone.sh "${clone_arguments[@]}" 1>&2; then
            files=copied
        else
            echo "failed|-|the copy failed"
            return
        fi
    fi

    status=0
    on "$host" "$root" deploy/server/load.sh --uniprot-version "$UNIPROT_VERSION" --check > /dev/null 2>&1 || status=$?
    # 1 is a load that is not whole, which loading again mends. 2 is an error, most often an
    # OpenSearch that did not say, where a load would drop an index that may be whole; which one,
    # load.sh --check on that server says.
    case "$status" in
        0) proteins=had ;;
        2) echo "${files}|failed|could not tell whether the proteins are loaded; load.sh --check there says why"; return ;;
        255) echo "${files}|failed|could not reach it to load"; return ;;
        *)
            log "${name}: loading the proteins of ${UNIPROT_VERSION}." 1>&2
            if on "$host" "$root" deploy/server/load.sh --uniprot-version "$UNIPROT_VERSION" 1>&2; then
                proteins=loaded
            else
                echo "${files}|failed|the load failed"
                return
            fi ;;
    esac

    echo "${files}|${proteins}|ready"
}

parse_arguments "$@"

SERVERS=$(read_servers)
[ -n "$SERVERS" ] || die "${SERVERS_FILE} lists no server."

SOURCE_OUTPUT_DIR=$(source_output_dir)
preflight_servers

results=''
failed=0
while read -r name host root; do
    result=$(distribute_to "$name" "$host" "$root")
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
    log "Every server has ${UNIPROT_VERSION}, with its proteins loaded. Switch each server to it with switch.sh --uniprot-version ${UNIPROT_VERSION}."
else
    log "Not every server is ready; the table says which, and the output above says why. A rerun picks up where this stopped."
fi
exit "$failed"
