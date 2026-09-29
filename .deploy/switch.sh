#!/usr/bin/env bash
#
# Switches the API on this host to another UniProtKB version it already holds: its files, copied or
# built beside the one in use, and its proteins, loaded into an index of their own. Run it with
# --help for the options.
#
# The API reads both when it starts: INDEX_LOCATION names the suffix array through the `current`
# link in OUTPUT_DIR, and the .version there names the index of its proteins. A switch is therefore
# moving that link while the API and OpenSearch are stopped, and starting both again.
#
# It stands on its own. It knows nothing of a load balancer: taking the host out of the pool first,
# where it is in one, is for whoever runs this.
#
# Flow:
#   1. Check everything a switch depends on while both are still running, and report every problem
#      rather than the first. A host with any is left exactly as it is. --check stops here.
#   2. Stop the API, then OpenSearch.
#   3. Point `current` at the new version, and `previous` at the one it pointed at.
#   4. Start OpenSearch, and wait for it and for the new version's index.
#   5. Close the indices of versions older than both of those, which frees the memory they hold.
#      Nothing is deleted: .deploy/prune.sh removes old versions.
#   6. Start the API, which checks the host once more and waits until it serves.
#   A failure in 4 or 6, or an interrupt from 2 on, points the links back and starts both on the
#   version it left, so the host serves what it served before.

set -eo pipefail
set -o errtrace

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"
# shellcheck source=../opensearch/lib.sh
source "${HERE}/../opensearch/lib.sh"

trap errorAndExit ERR
trap 'exit 2' USR1

read_conf

# The settings only this script has. After read_conf rather than before: a UNIPROT_VERSION in
# deploy.conf is the release clone.sh on this host fetches, not the one to switch to.

# The version to switch to.
UNIPROT_VERSION=

# Whether to switch to the version `previous` points at.
BACK=false

# Whether to only check.
CHECK_ONLY=false

# Seconds OpenSearch has to answer after it starts, and an index to be ready: the time the systemd
# drop-in install.sh writes gives OpenSearch itself.
readonly OPENSEARCH_START_TIMEOUT=600

usage() {
    cat <<'USAGE'
Switches the API on this host to another version it holds, stopping it and OpenSearch to do so.

  .deploy/switch.sh --uniprot-version YYYY-MM [OPTIONS]
  .deploy/switch.sh --back [OPTIONS]

  --uniprot-version V      the version to switch to. Its files and its proteins must be here
  --back                   switch to the version before, which `previous` points at
  --check                  only check that the switch can be made, and change nothing
  --output-dir DIR         where the databases are
  --opensearch-url URL     the instance their indices are in
  --help                   print this message

Run it as the user the API runs as. OpenSearch is stopped and started through sudo, which
install.sh allows that user for exactly those two commands.
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uniprot-version) need_value "$1" "${2-}"; UNIPROT_VERSION="$2"; shift 2 ;;
            --back) BACK=true; shift ;;
            --check) CHECK_ONLY=true; shift ;;
            --output-dir) need_value "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --opensearch-url) need_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) die "unknown option '$1'" ;;
        esac
    done

    if [ "$BACK" = true ]; then
        [ -z "$UNIPROT_VERSION" ] || die "--back switches to the version before; it takes no --uniprot-version."
    else
        [ -n "$UNIPROT_VERSION" ] || die "--uniprot-version or --back is required."
        valid_version "$UNIPROT_VERSION"
    fi
}

problems=0
# open or close, once check_host has found the index to switch to.
TARGET_STATUS=''
problem() {
    echo "  $*" 1>&2
    problems=$((problems + 1))
}

# Everything the switch depends on that can be known without changing anything, while the API and
# OpenSearch still run, so a host that cannot switch keeps serving exactly as it did. Every problem is
# reported.
check_host() {
    local location usage_text

    [ -d "$TARGET_DIR" ] \
        || problem "there is no ${TARGET_DIR}. Copy it with clone.sh, or build it, first."
    [ ! -d "$TARGET_DIR" ] || verify_database "${TARGET_DIR}/suffix-array" \
        || problem "${TARGET_DIR} is not a database the API can serve (above)."

    if [ ! -x "$API_DEPLOY" ]; then
        problem "there is no API here: ${API_DEPLOY} is missing. unipept-api's install puts it there."
    else
        usage_text=$("$API_DEPLOY" 2>&1 || true)
        [[ "$usage_text" == *"deploy.sh start"* ]] \
            || problem "${API_DEPLOY} has no stop and start: update unipept-api on this host first."
    fi

    location=$(api_index_location)
    [ "${location%/}" = "${CURRENT}/suffix-array" ] \
        || problem "INDEX_LOCATION in ${API_ENV_FILE} is '${location}', so the API would not follow the switch. Set it to ${CURRENT}/suffix-array."

    # The links are moved once both are stopped, where a failure would leave the host down.
    [ -w "$OUTPUT_DIR" ] || problem "${OUTPUT_DIR} is not writable by $(id -un), so ${CURRENT} cannot be moved."
    [ ! -e "$PREVIOUS" ] || [ -L "$PREVIOUS" ] \
        || problem "${PREVIOUS} is there and is not a link, so it cannot point at the version this host leaves."

    # A load writes to OpenSearch for hours, and stopping OpenSearch under it breaks it part way.
    # Held until the switch ends, so no load starts during it either.
    take_opensearch_lock -x || case $? in
        1) problem "a load is running on this host. Let it finish, or stop it, first." ;;
        *) problem "without the lock, a load could start while OpenSearch is stopped. Make ${OPENSEARCH_LOCK} writable for $(id -un), or set OPENSEARCH_LOCK." ;;
    esac

    { sudo -n -l systemctl stop opensearch && sudo -n -l systemctl start opensearch; } > /dev/null 2>&1 \
        || problem "${DEPLOY_USER} may not stop and start OpenSearch through sudo. Run .deploy/opensearch/install.sh again, as root."

    if ! opensearch_answers; then
        problem "OpenSearch does not answer at ${OPENSEARCH_URL}, so whether ${TARGET_INDEX} is there is unknown."
        return 0
    fi

    TARGET_STATUS=$(index_status "$TARGET_INDEX")
    if [ -z "$TARGET_STATUS" ]; then
        problem "${TARGET_INDEX} is not in OpenSearch. Load it with load.sh --uniprot-version ${TARGET}."
        return 0
    fi
    is_complete "$TARGET_INDEX" \
        || problem "${TARGET_INDEX} was not loaded to the end. Continue its load with --skip, or load it again."

    # The API's check searches the index, which it cannot do closed. Opening it is the one change
    # before the stop, made only once nothing else stands in the way; --check changes nothing, so it
    # says what it could not check.
    if [ "$TARGET_STATUS" = close ] && [ "$CHECK_ONLY" = true ]; then
        problem "${TARGET_INDEX} is closed, so the API's own check of ${TARGET} cannot run. Run this without --check: it opens the index before it stops anything."
    fi
}

# What the API itself needs of the new version, its files, the memory for them and the index of its
# proteins, which its own check decides. Opens a closed index first, which serves nothing new: the
# API does not query it until it is switched to.
check_api() {
    if [ "$TARGET_STATUS" = close ]; then
        opensearch_request "opening ${TARGET_INDEX}" "200" POST "${TARGET_INDEX}/_open" > /dev/null
        index_ready "$TARGET_INDEX" "$OPENSEARCH_START_TIMEOUT" \
            || { problem "${TARGET_INDEX} was opened and did not become ready within ${OPENSEARCH_START_TIMEOUT} seconds."; return 0; }
        log "Opened ${TARGET_INDEX}, which was closed."
    fi

    "$API_DEPLOY" check --index "${TARGET_DIR}/suffix-array" > /dev/null \
        || problem "the API's own check refuses ${TARGET_DIR}/suffix-array (above)."

    warn_opensearch_disk "$OPENSEARCH_URL"
}

wait_for_opensearch() {
    local deadline=$((SECONDS + OPENSEARCH_START_TIMEOUT))

    until opensearch_answers; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 3
    done
}

start_opensearch() {
    log "Starting OpenSearch."
    sudo -n systemctl start opensearch || return 1
    wait_for_opensearch || { echo "OpenSearch did not answer within ${OPENSEARCH_START_TIMEOUT} seconds." 1>&2; return 1; }
}

# The indices of versions older than both the one switched to and the one left: neither the API nor
# a --back needs them, and an open index holds memory. Versions newer than the one switched to are
# loaded ahead of a switch and stay open. uniprot_entries itself, which a host loaded before
# versioned indices still has beside the clone migrate.sh made, counts as the oldest: an API that
# switches queries the versioned one. Closing is not needed for the switch, so it happens once the
# API serves, and a failure is only reported.
close_older_indices() {
    local oldest="$TARGET" index status version

    [[ "$FROM" > "$oldest" ]] || oldest="$FROM"
    curl -s -f "${OPENSEARCH_URL}/_cat/indices/${ALIAS},${ALIAS}-*?h=index,status&expand_wildcards=all&ignore_unavailable=true" 2> /dev/null \
        | while read -r index status; do
            [ "$status" = open ] || continue
            version=$(version_of_index "$index")
            case $version in
                '') continue ;;
                legacy | plain) ;;
                *) [[ "$version" < "$oldest" ]] || continue ;;
            esac
            if curl -s -f -o /dev/null -X POST "${OPENSEARCH_URL}/${index}/_close"; then
                log "Closed ${index}, which neither version needs."
            else
                echo "WARN could not close ${index}; it keeps holding memory." 1>&2
            fi
        done || true
}

# Starts both on the version switched to. Fails at the first that does not come up.
start_both() {
    start_opensearch || return 1
    index_ready "$TARGET_INDEX" "$OPENSEARCH_START_TIMEOUT" \
        || { echo "${TARGET_INDEX} was not ready within ${OPENSEARCH_START_TIMEOUT} seconds." 1>&2; return 1; }
    log "Starting the API."
    "$API_DEPLOY" start
}

# Puts the links back and starts both on the version this left. Ends the script either way.
switch_back() {
    trap '' INT TERM HUP
    log "Switching back to ${FROM}."
    "$API_DEPLOY" stop || true
    # Only what moved, so a link that could not be moved is not tried again.
    [ "$(readlink "$CURRENT")" = "$FROM_LINK" ] || point_link "$CURRENT" "$FROM_LINK" \
        || die "could not point ${CURRENT} back at ${FROM_LINK}, and the API and OpenSearch may be stopped: this host needs attention."
    if [ -z "$PREVIOUS_LINK_WAS" ]; then
        rm -f "$PREVIOUS"
    elif [ "$(readlink "$PREVIOUS")" != "$PREVIOUS_LINK_WAS" ]; then
        point_link "$PREVIOUS" "$PREVIOUS_LINK_WAS" || true
    fi

    if { systemctl is-active --quiet opensearch 2> /dev/null && wait_for_opensearch; } || start_opensearch; then
        if index_ready "$FROM_INDEX" "$OPENSEARCH_START_TIMEOUT" && "$API_DEPLOY" start; then
            die "the switch to ${TARGET} failed (above). This host is back on ${FROM}, and serves it."
        fi
    fi
    die "the switch to ${TARGET} failed, and going back to ${FROM} did too (above): this host needs attention. ${CURRENT} points at ${FROM_LINK} again."
}

parse_arguments "$@"
refuse_root
checkdep flock "util-linux"

CURRENT=$(current_link)
PREVIOUS=$(previous_link)

[ -L "$CURRENT" ] \
    || die "there is no ${CURRENT}, so which version this host serves is not known. Run migrate.sh once: it sets it up from the API's INDEX_LOCATION."
FROM_LINK=$(readlink "$CURRENT")
FROM=$(linked_version "$CURRENT") || die "${CURRENT} points at ${FROM_LINK}, which is no version's directory."
FROM_INDEX="${ALIAS}-${FROM}"
PREVIOUS_LINK_WAS=$(readlink "$PREVIOUS" 2> /dev/null || true)

if [ "$BACK" = true ]; then
    TARGET=$(linked_version "$PREVIOUS") || die "there is no version to go back to: ${PREVIOUS} is not there."
else
    TARGET="$UNIPROT_VERSION"
fi
TARGET_DIR="${OUTPUT_DIR}/uniprot-${TARGET}"
TARGET_INDEX="${ALIAS}-${TARGET}"

if [ "$TARGET" = "$FROM" ]; then
    log "This host already serves ${TARGET}."
    exit 0
fi

log "Checking that this host can switch from ${FROM} to ${TARGET}."
check_host
[ "$problems" -eq 0 ] || die "${problems} problem(s), so nothing was changed."
# A --check on a closed index has stopped above, so what is left can be checked.
check_api
if [ "$problems" -gt 0 ]; then
    [ "$TARGET_STATUS" = close ] \
        && die "${problems} problem(s), so nothing was changed but opening ${TARGET_INDEX}, which serves nothing new."
    die "${problems} problem(s), so nothing was changed."
fi
if [ "$CHECK_ONLY" = true ]; then
    log "This host can switch from ${FROM} to ${TARGET}."
    exit 0
fi

# From the first stop on, anything that ends the script early has to leave the host serving.
trap 'echo "Interrupted." 1>&2; switch_back' INT TERM HUP

log "Stopping the API."
"$API_DEPLOY" stop || die "the API did not stop (above). Nothing was switched."
log "Stopping OpenSearch."
sudo -n systemctl stop opensearch || switch_back

{ point_link "$PREVIOUS" "$FROM_LINK" && point_link "$CURRENT" "uniprot-${TARGET}"; } || switch_back
log "${CURRENT} points at uniprot-${TARGET}."

start_both || switch_back

trap - INT TERM HUP
close_older_indices
log "This host serves ${TARGET}. ${FROM} is kept; switch back to it with --back."
