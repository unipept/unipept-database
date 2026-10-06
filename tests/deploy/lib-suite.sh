#!/usr/bin/env bash
#
# The parts of .deploy/lib.sh, function by function, for what the scripts that use them seldom or
# never reach: a tool that is not there, a failure nothing expected, an API binary that says nothing
# useful, paths that resolve to nothing. The rest each part does is checked through the scripts, in
# the verify, deploy and opensearch suites. Needs no container and no network.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "${HERE}/../../.deploy" && pwd)/lib.sh"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Runs code in a bash of its own that has sourced lib.sh, as a script does, with the options the
# scripts set. Its own process, since die signals the process that sourced lib.sh.
in_lib() {
    bash -c 'set -o pipefail; source "$1"; shift; eval "$1"' in_lib "$LIB" "$1"
}

# A script that sources lib.sh and arms its traps as the scripts in .deploy do, then runs the body.
lib_script() {
    local script="${TEMP_DIR}/$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -eo pipefail'
        echo 'set -o errtrace'
        echo "source '${LIB}'"
        echo 'trap errorAndExit ERR'
        echo "$2"
    } > "$script"
    chmod +x "$script"
    echo "$script"
}


section "core.sh: checkdep"

output=$(in_lib 'checkdep no-such-tool-here "the tool"' 2>&1)
check "a tool that is not there stops the script" "$?" "6"
check "and says what to install" "$output" "This script requires the tool to be installed."

# On a host without which, the shell's own lookup still finds what is on the PATH.
mkdir -p "${TEMP_DIR}/bin"
ln -s "$(command -v bash)" "${TEMP_DIR}/bin/bash"
printf '#!/bin/sh\n' > "${TEMP_DIR}/bin/some-tool"
chmod +x "${TEMP_DIR}/bin/some-tool"
# shellcheck disable=SC2016 # expanded by the bash it starts
PATH="${TEMP_DIR}/bin" "${TEMP_DIR}/bin/bash" -c 'source "$1"; checkdep some-tool' _ "$LIB" > /dev/null 2>&1
check "without which, a tool on the PATH is still found" "$?" "0"


section "core.sh: errorAndExit"

script=$(lib_script failing.sh 'false')
output=$("$script" 2>&1)
check "a command that fails where nothing expected it stops the script" "$?" "2"
check "and names the script, the command, and the line of the file it is on" "$output" \
    "Error: failing.sh stopped: 'false' failed with exit status 1 at line 6 of ${script}."

script=$(lib_script failing-in-lib.sh "swap_into_place '${TEMP_DIR}/no-such-staging' '${TEMP_DIR}/target'")
output=$("$script" 2> "${TEMP_DIR}/stderr")
check "a command that fails in a part of lib.sh stops the script" "$?" "2"
check_true "and names that part, not the script, as where" \
    grep -q "stopped: 'mv \"\$staging\" \"\$target\"' failed with exit status 1 at line [0-9]* of ${LIB%/lib.sh}/lib/database.sh\.\$" "${TEMP_DIR}/stderr"

# shellcheck disable=SC2016 # expanded by the script it writes
script=$(lib_script fails-inside.sh 'inner() { false; echo "went on"; }
result=$(inner)')
output=$("$script" 2>&1)
check "a command that fails inside a command substitution stops the script" "$?" "2"
check "and is reported once, at the line that started it" "$output" \
    "Error: fails-inside.sh stopped: 'result=\$(inner)' failed with exit status 1 at line 7 of ${script}."

# As install.sh asks dpkg-query about a package that may not be there.
# shellcheck disable=SC2016 # expanded by the script it writes
script=$(lib_script expected-inside.sh 'read -r answer < <(false) || true
x=$(false) || true
echo "went on"')
output=$("$script" 2>&1)
check "a failure the script expects, inside a substitution, does not stop it" "$?" "0"
check "nor is it reported" "$output" "went on"


section "core.sh: die"

# shellcheck disable=SC2016 # expanded by the script it writes
script=$(lib_script dies-inside.sh 'version=$(die "inside a substitution")
echo "went on with ${version}"')
output=$("$script" 2>&1)
check "a die inside a command substitution stops the script itself" "$?" "2"
check "and is reported once, by die alone" "$output" "Error: inside a substitution"


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


summary
