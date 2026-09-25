#!/usr/bin/env bash
#
# The deploy cases. Runs inside the container build-suite.sh starts, with the repository at /repo
# read-only and everything this writes under /work.
#
# What is real here: build.sh and clone.sh themselves, git, ssh and scp. What is stood in for: the
# pipeline, sa-builder and the OpenSearch loader, each of which has a suite of its own.

set -uo pipefail

# shellcheck source=../lib.sh
source /repo/tests/lib.sh

readonly WORK=/work
readonly CHECKOUT="${WORK}/checkout"
readonly INDEX_REPO="${WORK}/unipept-index"
readonly STUBS="${WORK}/stubs"

export PATH="${STUBS}:${PATH}"

# A checkout of this repository holding the deploy scripts and stand-ins for what they call. The
# real repository is read-only, and the point is to replace the expensive parts.
setup_checkout() {
    rm -rf "${CHECKOUT:?}"
    mkdir -p "${CHECKOUT}"/{.deploy,pipelines/lib,pipelines/suffix-array,opensearch,assets}

    cp /repo/.deploy/*.sh "${CHECKOUT}/.deploy/"
    cp /repo/pipelines/lib/common.sh "${CHECKOUT}/pipelines/lib/"
    printf '{"sample":true}\n' > "${CHECKOUT}/assets/sampledata.json"

    # The pipeline: writes the seven tables and the .version, and nothing else it writes matters
    # here. tests/run-tests.sh build covers the real one.
    cat > "${CHECKOUT}/pipelines/suffix-array/build.sh" <<'PIPELINE'
#!/usr/bin/env bash
set -eo pipefail
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUT="$2"; shift 2 ;;
        *) shift 2 ;;
    esac
done
mkdir -p "$OUT"
for table in uniprot_entries taxons lineages interpro_entries go_terms ec_numbers proteomes; do
    printf '1\tP12345\t1\t9606\tswissprot\tname\tMSEQ\tGO:0005515\n' | lz4 -c > "${OUT}/${table}.tsv.lz4"
done
printf '%s\n' "${STUB_UNIPROT_VERSION:-2026.03}" > "${OUT}/.version"
PIPELINE

    # The loader: records that it was called, on what. tests/run-tests.sh opensearch covers the
    # real one against a real OpenSearch.
    cat > "${CHECKOUT}/opensearch/load.sh" <<'LOADER'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "$*" >> /work/loader-calls
LOADER

    chmod +x "${CHECKOUT}/pipelines/suffix-array/build.sh" "${CHECKOUT}/opensearch/load.sh"

    # Through the configuration file, which is how a host sets this, so the suite covers that path
    # too. It also keeps the run offline: without it build.sh clones unipept-index from GitHub.
    printf 'INDEX_REPO=%s\n' "$INDEX_REPO" > "${CHECKOUT}/.deploy/deploy.conf"

    git -C "$CHECKOUT" init -q
    printf '.deploy/deploy.conf\n' > "${CHECKOUT}/.gitignore"
    git -C "$CHECKOUT" add -A
    git -C "$CHECKOUT" -c user.email=t@example.com -c user.name=t commit -qm "the checkout under test"
}

# A repository build.sh clones for sa-builder. A real clone of a real repository, over a path
# rather than the network, so clone_repo and the commit it records are the real ones.
setup_index_repo() {
    rm -rf "${INDEX_REPO:?}"
    mkdir -p "${INDEX_REPO}/target/release"

    printf '[package]\nname = "stand-in"\n' > "${INDEX_REPO}/Cargo.toml"
    cat > "${INDEX_REPO}/target/release/sa-builder" <<'SA'
#!/usr/bin/env bash
set -eo pipefail
prev=''
for arg in "$@"; do
    case "$prev" in
        --output-sa | --output-proteins | --output-mapping | --output-kmer-table)
            printf 'binary\n' > "$arg" ;;
    esac
    prev="$arg"
done
printf '%s\n' "$*" >> /work/sa-builder-calls
SA
    chmod +x "${INDEX_REPO}/target/release/sa-builder"

    git -C "$INDEX_REPO" init -q
    git -C "$INDEX_REPO" add -A
    git -C "$INDEX_REPO" -c user.email=t@example.com -c user.name=t commit -qm "stand-in index"
}

# cargo and cmake are only checked for and called; building the index is not what is under test.
setup_stubs() {
    mkdir -p "$STUBS"
    for tool in cargo cmake; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS}/${tool}"
        chmod +x "${STUBS}/${tool}"
    done
}

# An sshd on this container, so clone.sh reaches a "remote host" through a real ssh and a real scp.
setup_sshd() {
    mkdir -p /run/sshd /root/.ssh
    ssh-keygen -A > /dev/null 2>&1
    ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_test
    cat /root/.ssh/id_test.pub > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    printf 'PermitRootLogin prohibit-password\n' >> /etc/ssh/sshd_config
    /usr/sbin/sshd

    # clone.sh runs ssh without StrictHostKeyChecking=no, as it does on a real host, so the key has
    # to be known before it runs.
    ssh-keyscan -H localhost >> /root/.ssh/known_hosts 2>/dev/null
}

# For check_true, which runs a command rather than evaluating an expression.
not() { ! "$@"; }

build() {
    "${CHECKOUT}/.deploy/build.sh" "$@" > /work/last-output 2>&1
}

clone() {
    "${CHECKOUT}/.deploy/clone.sh" \
        --remote-address localhost --remote-user root --remote-port 22 \
        --local-ssh-key /root/.ssh/id_test "$@" > /work/last-output 2>&1
}

mkdir -p "$WORK"
setup_stubs
setup_index_repo
setup_checkout
setup_sshd


section "a clean build"

OUT=/work/data
mkdir -p "$OUT"
build --output-dir "$OUT" --scratch-dir /work/scratch --opensearch-url http://stub:9200
check "the build succeeds" "$?" "0"
check_true "the database is named after the version the pipeline wrote" \
    test -d "${OUT}/uniprot-2026-03"
check_true "verify.sh passes on it" \
    "${CHECKOUT}/.deploy/verify.sh" --index-dir "${OUT}/uniprot-2026-03/suffix-array"
check_true "the staging directory is gone" test ! -d "${OUT}/.build"
check_true "the entries table is kept for clone.sh" \
    test -s "${OUT}/uniprot-2026-03/tables/uniprot_entries.tsv.lz4"
check_true "the k-mer table is built" \
    test -s "${OUT}/uniprot-2026-03/suffix-array/kmer_table.bin"
check "sa-builder was asked for the k-mer table" \
    "$(grep -c -- '--output-kmer-table' /work/sa-builder-calls)" "1"
check "the proteins were loaded" \
    "$(grep -c -- '--uniprot-entries' /work/loader-calls)" "1"

check "build-info.txt records this checkout" \
    "$(grep '^unipept-database:' "${OUT}/uniprot-2026-03/suffix-array/build-info.txt" | awk '{print $2}')" \
    "$(git -C "$CHECKOUT" rev-parse HEAD)"
check "build-info.txt records the index it cloned" \
    "$(grep '^unipept-index:' "${OUT}/uniprot-2026-03/suffix-array/build-info.txt" | awk '{print $2}')" \
    "$(git -C "$INDEX_REPO" rev-parse HEAD)"


section "a build of a version that is already there"

printf 'do not lose me\n' > "${OUT}/uniprot-2026-03/marker"
build --output-dir "$OUT" --scratch-dir /work/scratch
check "it stops" "$?" "2"
check_true "the database that was there is untouched" test -f "${OUT}/uniprot-2026-03/marker"
check_true "its own result is kept for inspection" test -d "${OUT}/.build"
check_true "it says how to replace it" grep -q -- '--replace' /work/last-output

build --output-dir "$OUT" --scratch-dir /work/scratch --replace
check "--replace succeeds" "$?" "0"
check_true "the old database is gone" test ! -f "${OUT}/uniprot-2026-03/marker"
check_true "nothing is left beside it" test ! -e "${OUT}/uniprot-2026-03.replaced"


section "a build whose tables are empty"

# An archive of an empty stream has bytes, so the table passes every check made on the .lz4 and
# yields nothing when it is read.
# shellcheck disable=SC2016 # OUT belongs to the stub pipeline, and expands when it runs
printf '\nprintf "" | lz4 -c > "${OUT}/taxons.tsv.lz4"\n' >> "${CHECKOUT}/pipelines/suffix-array/build.sh"
EMPTY_OUT=/work/data-empty
mkdir -p "$EMPTY_OUT"
rm -f /work/loader-calls
build --output-dir "$EMPTY_OUT" --scratch-dir /work/scratch
check "it stops" "$?" "2"
check_true "the empty table is named" grep -q 'datastore/taxons.tsv is empty' /work/last-output
check_true "no database is put in place" test ! -d "${EMPTY_OUT}/uniprot-2026-03"
# The loader drops and recreates the index the API queries, so a refused build must not reach it.
check_true "the proteins OpenSearch serves are left alone" test ! -s /work/loader-calls
git -C "$CHECKOUT" checkout -q -- pipelines/suffix-array/build.sh


section "cloning over a real ssh and scp"

REMOTE=/work/remote
LOCAL=/work/local
mkdir -p "$REMOTE" "$LOCAL"
cp -r "${OUT}/uniprot-2026-03" "${REMOTE}/uniprot-2026-03"
cp -r "${OUT}/uniprot-2026-03" "${REMOTE}/uniprot-2025-11"
printf '2025.11\n' > "${REMOTE}/uniprot-2025-11/suffix-array/.version"
# What an interrupted swap leaves behind on the remote. It sorts after the database it replaced.
cp -r "${OUT}/uniprot-2026-03" "${REMOTE}/uniprot-2026-03.replaced"

clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --opensearch-url http://stub:9200
check "the clone succeeds" "$?" "0"
check_true "the newest release on the remote is the one taken" test -d "${LOCAL}/uniprot-2026-03"
check_true "a leftover beside it is not taken for a release" test ! -e "${LOCAL}/uniprot-2026-03.replaced"
check_true "the older one is left alone" test ! -d "${LOCAL}/uniprot-2025-11"
check_true "the copy lands where the script looks for it" \
    test -s "${LOCAL}/uniprot-2026-03/suffix-array/sa.bin"
check_true "verify.sh passes on the copy" \
    "${CHECKOUT}/.deploy/verify.sh" --index-dir "${LOCAL}/uniprot-2026-03/suffix-array"
check_true "the staging directory is gone" test ! -d "${LOCAL}/.clone"

clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --uniprot-version 2025-11
check "an older release can be named" "$?" "0"
check_true "it is the one that arrives" test -d "${LOCAL}/uniprot-2025-11"


section "a clone that cannot be made"

clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --uniprot-version 2030-01
check "a release the remote does not have stops" "$?" "2"
check_true "the release is named" grep -q 'uniprot-2030-01' /work/last-output

clone --remote-output-dir /work/nothing-here --output-dir "$LOCAL"
check "a remote with no database stops" "$?" "2"

# An scp that loses the k-mer table on the way, which the remote has.
cat > "${STUBS}/scp" <<SCP
#!/usr/bin/env bash
/usr/bin/scp "\$@" || exit
rm -f ${LOCAL}/.clone/*/suffix-array/kmer_table.bin
SCP
chmod +x "${STUBS}/scp"
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --replace
check "a copy that lost the k-mer table stops" "$?" "2"
check_true "it says the copy lost it" grep -q 'the remote has a k-mer table and the copy does not' /work/last-output
check_true "it does not first call the table optional" not grep -q 'WARN kmer_table.bin' /work/last-output
check_true "the database that was there is kept" test -s "${LOCAL}/uniprot-2026-03/suffix-array/kmer_table.bin"
rm "${STUBS}/scp"

rm "${REMOTE}/uniprot-2026-03/suffix-array/mapping.bin"
rm -rf "${LOCAL}/uniprot-2026-03" "${LOCAL}/.clone"
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL"
check "an incomplete database on the remote stops" "$?" "2"
check_true "the missing file is named" grep -q 'mapping.bin is missing' /work/last-output
check_true "it stops before copying anything" test ! -e "${LOCAL}/.clone"
check_true "nothing is put in place" test ! -d "${LOCAL}/uniprot-2026-03"


summary
