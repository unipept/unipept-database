#!/usr/bin/env bash
#
# .deploy/verify.sh against a fixture index directory. Needs no container and no network: what it
# checks is a directory layout.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

# shellcheck source=../../.deploy/lib.sh
source "${HERE}/../../.deploy/lib.sh"

VERIFY="${HERE}/../../.deploy/verify.sh"

# verify.sh refuses root, because root reads everything and its check is whether the API can read
# the files. The container suite checks that refusal; here there is nothing else to run.
if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP running as root, which verify.sh refuses"
    exit 0
fi

TEMP_DIR="$(mktemp -d)"
# The permission cases take access away, and rm cannot clear what it cannot enter.
trap 'chmod -R u+rwx "${TEMP_DIR}" 2>/dev/null; rm -rf "${TEMP_DIR}"' EXIT

# A whole database, which every case then takes one thing away from. Written fresh each time, so a
# case cannot inherit what the one before it broke.
make_index() {
    local root="$1" index="${1}/uniprot-2026-03/suffix-array" relative

    chmod -R u+rwx "${root}" 2>/dev/null
    rm -rf "${root:?}"

    for relative in "${INDEX_FILES[@]}" "${OPTIONAL_INDEX_FILES[@]}"; do
        mkdir -p "$(dirname "${index}/${relative}")"
        printf 'content\n' > "${index}/${relative}"
    done

    printf '2026.03\n' > "${index}/.version"
    printf 'uniprot: 2026-03\n' > "${index}/build-info.txt"

    echo "$index"
}

# Whether the output of the last verify.sh run contains the text.
said() { grep -qF -- "$1" <<< "$output"; }
not_said() { ! said "$1"; }

INDEX="$(make_index "${TEMP_DIR}/whole")"


section "a whole database"

"$VERIFY" --index-dir "$INDEX" > /dev/null 2>&1
check "passes" "$?" "0"


section "each required file missing in turn"

for required in "${INDEX_FILES[@]}"; do
    index="$(make_index "${TEMP_DIR}/missing")"
    rm "${index}/${required}"

    output="$("$VERIFY" --index-dir "$index" 2>&1)"
    check "${required} missing fails" "$?" "1"
    check_true "${required} is named" said "${required} is missing"
done


section "each required file empty in turn"

for required in "${INDEX_FILES[@]}"; do
    index="$(make_index "${TEMP_DIR}/empty")"
    : > "${index}/${required}"

    output="$("$VERIFY" --index-dir "$index" 2>&1)"
    check "${required} empty fails" "$?" "1"
    check_true "${required} is reported empty" said "${required} is empty"
done


section "every datastore table the build writes is checked"

for table in "${DATASTORE_TABLES[@]}"; do
    index="$(make_index "${TEMP_DIR}/table")"
    rm "${index}/datastore/${table}.tsv"

    "$VERIFY" --index-dir "$index" > /dev/null 2>&1
    check "without ${table}.tsv it fails" "$?" "1"
done


section "every failure is reported, not the first"

index="$(make_index "${TEMP_DIR}/several")"
rm "${index}/sa.bin" "${index}/datastore/taxons.tsv" "${index}/datastore/go_terms.tsv"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "three missing files give three failures" "$(printf '%s\n' "$output" | grep -c '^FAIL')" "3"


section "an optional file"

for optional in "${OPTIONAL_INDEX_FILES[@]}"; do
    index="$(make_index "${TEMP_DIR}/optional")"
    rm "${index}/${optional}"

    output="$("$VERIFY" --index-dir "$index" 2>&1)"
    check "${optional} missing still passes" "$?" "0"
    check_true "${optional} is warned about" said "WARN ${optional}"
done


section "files that are there and cannot be read"

index="$(make_index "${TEMP_DIR}/unreadable-file")"
chmod 000 "${index}/sa.bin"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "an unreadable file fails" "$?" "1"
check_true "it is reported unreadable" said "sa.bin is not readable"

index="$(make_index "${TEMP_DIR}/unreadable-dir")"
chmod 000 "${index}/datastore"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "an unreadable datastore fails" "$?" "1"
check_true "the directory is reported unreadable" said "datastore/ is not readable"
check_true "its tables are not reported missing" not_said "is missing"

index="$(make_index "${TEMP_DIR}/unreadable-version")"
chmod 000 "${index}/.version"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "an unreadable .version fails" "$?" "1"
check_true "it is reported unreadable" said ".version is not readable"
check_true "it is not also reported as a version mismatch" not_said ".version says"


section "the directory name and .version"

index="$(make_index "${TEMP_DIR}/mismatch")"
printf '2025.11\n' > "${index}/.version"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "a version that is not the directory's fails" "$?" "1"
check_true "both versions are named" said "the directory says 2026-03 and .version says 2025-11"


section "build-info.txt"

index="$(make_index "${TEMP_DIR}/noinfo")"
rm "${index}/build-info.txt"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "a database without one still passes" "$?" "0"
check_true "its absence is warned about" said "WARN build-info.txt"


section "choosing what to check"

root="${TEMP_DIR}/several-versions"
make_index "$root" > /dev/null
cp -R "${root}/uniprot-2026-03" "${root}/uniprot-2025-11"
printf '2025.11\n' > "${root}/uniprot-2025-11/suffix-array/.version"

output="$("$VERIFY" --output-dir "$root" 2>&1)"
check "the newest is taken when no version is given" "$?" "0"
check_true "the newest is the one checked" said "uniprot-2026-03/suffix-array"

"$VERIFY" --output-dir "$root" --uniprot-version 2025-11 > /dev/null 2>&1
check "an older one can be named" "$?" "0"

# What an interrupted swap leaves behind, and a copy an operator kept. Both sort after the database
# they are a copy of, and neither is a database.
cp -R "${root}/uniprot-2026-03" "${root}/uniprot-2026-03.replaced"
cp -R "${root}/uniprot-2026-03" "${root}/uniprot-2026-03.bak"
output="$("$VERIFY" --output-dir "$root" 2>&1)"
check "a leftover beside the newest does not change the result" "$?" "0"
check_true "the database is checked, not the leftover" said "Checking ${root}/uniprot-2026-03/suffix-array"

"$VERIFY" --output-dir "${TEMP_DIR}/nothing-here" > /dev/null 2>&1
check "no database at all is an error" "$?" "2"

"$VERIFY" --index-dir "$INDEX" --uniprot-version 2026-03 > /dev/null 2>&1
check "two ways of naming one database is an error" "$?" "2"


section "a deploy.conf that pins the version clone.sh fetches"

# verify.sh reads deploy.conf beside itself, so this runs a copy of the scripts with one there.
checkout="${TEMP_DIR}/checkout"
mkdir -p "${checkout}/.deploy" "${checkout}/pipelines/lib"
cp "${HERE}"/../../.deploy/*.sh "${checkout}/.deploy/"
cp "${HERE}/../../pipelines/lib/common.sh" "${checkout}/pipelines/lib/"
printf 'OUTPUT_DIR=%s\nUNIPROT_VERSION=2025-11\n' "$root" > "${checkout}/.deploy/deploy.conf"

output="$("${checkout}/.deploy/verify.sh" --index-dir "$INDEX" 2>&1)"
check "--index-dir still works" "$?" "0"

output="$("${checkout}/.deploy/verify.sh" 2>&1)"
check "with no flags it passes" "$?" "0"
check_true "the newest is checked, not the pinned one" said "uniprot-2026-03/suffix-array"


summary
