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

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# A whole database, which every case then takes one thing away from. Written fresh each time, so a
# case cannot inherit what the one before it broke.
make_index() {
    local root="$1" index="${1}/uniprot-2026-03/suffix-array" relative

    rm -rf "${root:?}"
    mkdir -p "${index}/datastore"

    for relative in $INDEX_FILES $OPTIONAL_INDEX_FILES; do
        mkdir -p "$(dirname "${index}/${relative}")"
        printf 'content\n' > "${index}/${relative}"
    done

    printf '2026.03\n' > "${index}/.version"
    printf 'uniprot: 2026-03\n' > "${index}/build-info.txt"

    echo "$index"
}

INDEX="$(make_index "${TEMP_DIR}/whole")"


section "a whole database"

"$VERIFY" --index-dir "$INDEX" > /dev/null 2>&1
check "passes" "$?" "0"


section "each required file missing in turn"

for required in $INDEX_FILES; do
    index="$(make_index "${TEMP_DIR}/missing")"
    rm "${index}/${required}"

    output="$("$VERIFY" --index-dir "$index" 2>&1)"
    status=$?

    check "${required} missing fails" "$status" "1"
    case "$output" in
        *"${required}"*) check "${required} is named" yes yes ;;
        *) check "${required} is named" "no" "yes" ;;
    esac
done


section "each required file empty in turn"

for required in $INDEX_FILES; do
    index="$(make_index "${TEMP_DIR}/empty")"
    : > "${index}/${required}"

    output="$("$VERIFY" --index-dir "$index" 2>&1)"
    status=$?

    check "${required} empty fails" "$status" "1"
    case "$output" in
        *"${required} is empty"*) check "${required} is reported empty" yes yes ;;
        *) check "${required} is reported empty" "no" "yes" ;;
    esac
done


section "every failure is reported, not the first"

index="$(make_index "${TEMP_DIR}/several")"
rm "${index}/sa.bin" "${index}/datastore/taxons.tsv" "${index}/datastore/go_terms.tsv"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "three missing files give three failures" "$(printf '%s\n' "$output" | grep -c '^FAIL')" "3"


section "an optional file"

for optional in $OPTIONAL_INDEX_FILES; do
    index="$(make_index "${TEMP_DIR}/optional")"
    rm "${index}/${optional}"

    output="$("$VERIFY" --index-dir "$index" 2>&1)"
    status=$?

    check "${optional} missing still passes" "$status" "0"
    case "$output" in
        *"WARN ${optional}"*) check "${optional} is warned about" yes yes ;;
        *) check "${optional} is warned about" "no" "yes" ;;
    esac
done


section "the directory name and .version"

index="$(make_index "${TEMP_DIR}/mismatch")"
printf '2025.11\n' > "${index}/.version"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "a version that is not the directory's fails" "$?" "1"
case "$output" in
    *"2026-03"*"2025-11"*) check "both versions are named" yes yes ;;
    *) check "both versions are named" "no" "yes" ;;
esac


section "build-info.txt"

index="$(make_index "${TEMP_DIR}/noinfo")"
rm "${index}/build-info.txt"
output="$("$VERIFY" --index-dir "$index" 2>&1)"
check "a database without one still passes" "$?" "0"
case "$output" in
    *"WARN build-info.txt"*) check "its absence is warned about" yes yes ;;
    *) check "its absence is warned about" "no" "yes" ;;
esac


section "choosing what to check"

root="${TEMP_DIR}/several-versions"
make_index "$root" > /dev/null
cp -R "${root}/uniprot-2026-03" "${root}/uniprot-2025-11"
printf '2025.11\n' > "${root}/uniprot-2025-11/suffix-array/.version"

output="$("$VERIFY" --output-dir "$root" 2>&1)"
check "the newest is taken when no version is given" "$?" "0"
case "$output" in
    *uniprot-2026-03*) check "the newest is the one checked" yes yes ;;
    *) check "the newest is the one checked" "no" "yes" ;;
esac

"$VERIFY" --output-dir "$root" --uniprot-version 2025-11 > /dev/null 2>&1
check "an older one can be named" "$?" "0"

"$VERIFY" --output-dir "${TEMP_DIR}/nothing-here" > /dev/null 2>&1
check "no database at all is an error" "$?" "2"

"$VERIFY" --index-dir "$INDEX" --uniprot-version 2026-03 > /dev/null 2>&1
check "two ways of naming one database is an error" "$?" "2"


summary
