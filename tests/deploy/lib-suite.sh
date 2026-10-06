#!/usr/bin/env bash
#
# The parts of .deploy/lib.sh, function by function, for what the scripts that use them seldom or
# never reach: core.sh's cases, which every repository that shares it runs, and then this
# repository's own: an API binary that says nothing useful, paths that resolve to nothing. The
# rest each part does is checked through the scripts, in the verify, deploy and opensearch suites.
# Needs no container and no network.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "${HERE}/../../.deploy" && pwd)/lib.sh"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# What lib/core.sh does, the same cases as every repository that shares it.
# shellcheck source=core-cases.sh
source "${HERE}/core-cases.sh"

# Runs code in a bash of its own that has sourced lib.sh, as a script does, and exits with the
# status of that code. Its own process, since die signals the process that sourced lib.sh. The code
# runs where a failure is expected, as in an `if`, so a function that returns non-zero says so here
# rather than tripping the error trap.
in_lib() {
    # shellcheck disable=SC2016 # expanded by the bash it starts
    bash -c 'source "$1"; shift; eval "$1" || exit $?' in_lib "$LIB" "$1"
}


section "api.sh: api_follows_current"

mkdir -p "${TEMP_DIR}/data"
printf 'INDEX_LOCATION=%s/data/current/suffix-array/\n' "$TEMP_DIR" > "${TEMP_DIR}/api.env"
in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/data'; api_follows_current"
check "an INDEX_LOCATION through current in OUTPUT_DIR follows it" "$?" "0"

ln -s "${TEMP_DIR}/data" "${TEMP_DIR}/data-link"
in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/data-link/'; api_follows_current"
check "as does an OUTPUT_DIR that is a link to that directory" "$?" "0"

mkdir -p "${TEMP_DIR}/elsewhere"
in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/elsewhere'; api_follows_current"
check "a current in another directory is not followed" "$?" "1"

printf 'INDEX_LOCATION=%s/gone/away/current/suffix-array\n' "$TEMP_DIR" > "${TEMP_DIR}/gone.env"
in_lib "API_ENV_FILE='${TEMP_DIR}/gone.env' OUTPUT_DIR='${TEMP_DIR}/not/there'; api_follows_current"
check "two paths that resolve to nothing are not the same one" "$?" "1"

in_lib "API_ENV_FILE='${TEMP_DIR}/api.env' OUTPUT_DIR='${TEMP_DIR}/not/there'; api_follows_current"
check "nor is an OUTPUT_DIR that resolves to nothing" "$?" "1"

printf 'INDEX_LOCATION=%s/data/uniprot-2026-03/suffix-array\n' "$TEMP_DIR" > "${TEMP_DIR}/direct.env"
in_lib "API_ENV_FILE='${TEMP_DIR}/direct.env' OUTPUT_DIR='${TEMP_DIR}/data'; api_follows_current"
check "an INDEX_LOCATION that names a version's directory itself does not follow current" "$?" "1"


section "api.sh: api_binary_version and api_state"

# A stand-in API binary that answers --version with what it is given.
fake_api() {
    local binary="${TEMP_DIR}/api-$1"
    printf '#!/bin/sh\n%s\n' "$2" > "$binary"
    chmod +x "$binary"
    echo "$binary"
}

check "the version is the last word of what --version prints" \
    "$(in_lib "api_binary_version '$(fake_api plain 'echo unipept-api 2.7.0')'")" "2.7.0"
check "without a pre-release suffix" \
    "$(in_lib "api_binary_version '$(fake_api rc 'echo unipept-api 2.7.0-rc.1')'")" "2.7.0"

in_lib "api_binary_version '$(fake_api failing 'echo unipept-api 2.7.0; exit 3')'" > /dev/null
check "a binary whose --version fails has no version" "$?" "1"
in_lib "api_binary_version '$(fake_api garbled 'echo unipept-api, built today')'" > /dev/null
check "nor does one that prints no X.Y.Z" "$?" "1"
in_lib "api_binary_version '${TEMP_DIR}/no-such-binary'" > /dev/null
check "nor one that is not there" "$?" "1"

in_lib "api_state '$(fake_api new 'echo unipept-api 2.7.0')'"
check "a release since API_VERSIONED_INDEX_SINCE queries the versioned index" "$?" "0"
in_lib "api_state '$(fake_api newer 'echo unipept-api 2.10.0')'"
check "and so does a later one, compared as versions rather than text" "$?" "0"
in_lib "api_state '$(fake_api old 'echo unipept-api 2.6.4')'"
check "an older release does not" "$?" "1"
in_lib "api_state '$(fake_api garbled 'echo unipept-api, built today')'"
check "and one that cannot say is neither" "$?" "2"


section "api.sh: is_served"

# What OpenSearch says is replaced, so the links alone decide, and the case of an OpenSearch that
# answers but does not say what the alias points at can be made.
mkdir -p "${TEMP_DIR}/served/uniprot-2026-03"
ln -s uniprot-2026-03 "${TEMP_DIR}/served/current"
answers_without_alias="OUTPUT_DIR='${TEMP_DIR}/served' API_ENV_FILE=/nonexistent
opensearch_answers() { return 0; }
alias_targets() { return 1; }"

in_lib "${answers_without_alias}; is_served 2026-03"
check "what current points at is served" "$?" "0"
in_lib "${answers_without_alias}; is_served 2026-04"
check "another version is not" "$?" "1"

output=$(in_lib "${answers_without_alias}; is_served 2026-04 strict" 2>&1)
check "strict, an alias OpenSearch does not report stops the script" "$?" "2"
check_true "and says what is not known" grep -q "so what this host serves is not known" <<< "$output"

in_lib "OUTPUT_DIR='${TEMP_DIR}/served' API_ENV_FILE=/nonexistent
opensearch_answers() { return 1; }
alias_targets() { return 1; }
is_served 2026-04 strict"
check "an OpenSearch that does not answer at all leaves it to the links" "$?" "1"


section "every script's --help"

# Every option in one column, and which setting wins said the same way. From a copy with an empty
# deploy.conf of its own, which a script reads before any other, and install.sh with a --prefix of
# its own, so no deploy.conf on this machine is read or checked first.
copy_deploy_scripts "${HERE}/../.." "${TEMP_DIR}/checkout"
DEPLOY="${TEMP_DIR}/checkout/.deploy"
: > "${DEPLOY}/deploy.conf"
for script in build clone distribute load migrate prune switch verify opensearch/install; do
    arguments=(--help)
    [ "$script" != opensearch/install ] || arguments=(--prefix "${TEMP_DIR}/prefix" --help)
    output=$("${DEPLOY}/${script}.sh" "${arguments[@]}" 2>&1)
    check "${script}.sh --help exits 0" "$?" "0"
    check_true "and lists its options" grep -q '^  --' <<< "$output"
    check "and every option line has its text in the thirtieth column" \
        "$(awk '/^  --/ && (substr($0, 29, 1) != " " || substr($0, 30, 1) == " ")' <<< "$output" | wc -l | tr -d ' ')" "0"
    check_true "and says that a flag wins over deploy.conf" \
        grep -q '^A flag wins over .*deploy.conf, which wins over the defaults' <<< "$output"
done

# The version clone.sh copies can come from deploy.conf, so it is checked there too.
printf 'UNIPROT_VERSION=2026.03\n' > "${DEPLOY}/deploy.conf"
output=$("${DEPLOY}/clone.sh" --remote-address host --local-ssh-key key 2>&1)
check "clone.sh refuses a version in deploy.conf not written YYYY-MM" "$?" "2"
check "and says how to write it" "$output" "Error: a UniProtKB version is written YYYY-MM, not '2026.03'."
: > "${DEPLOY}/deploy.conf"

# Every script that takes --uniprot-version checks it is written YYYY-MM, before anything else.
for script in clone distribute load switch verify; do
    output=$("${DEPLOY}/${script}.sh" --uniprot-version 2026.03 2>&1)
    check "${script}.sh refuses --uniprot-version 2026.03" "$?" "2"
    check "and says how to write it" "$output" "Error: a UniProtKB version is written YYYY-MM, not '2026.03'."
done

output=$("${DEPLOY}/build.sh" --opensearch-url http://localhost:9200 2>&1)
check "build.sh, which loads nothing into OpenSearch, refuses --opensearch-url" "$?" "2"
check "as an unknown option" "$output" "Error: unknown option '--opensearch-url'. Run with --help for the options."


summary
