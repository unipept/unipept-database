#!/usr/bin/env bash
#
# The deploy cases. Runs inside the container build-suite.sh starts, with the repository at /repo
# read-only and everything this writes under /work.
#
# What is real here: build.sh, clone.sh, verify.sh and install.sh themselves, git, ssh and scp. What
# is stood in for: the pipeline, sa-builder and the OpenSearch loader, each of which has a suite of
# its own, and the apt, dpkg, systemd and instance install.sh drives.
#
# The cases run as root, which setting up sshd and install.sh need. build.sh, clone.sh and verify.sh
# run as DEPLOY, as on a host, and refuse root.

set -uo pipefail

# shellcheck source=../lib.sh
source /repo/tests/lib.sh
# shellcheck source=stubs.sh
source /repo/tests/deploy/stubs.sh

readonly WORK=/work
readonly CHECKOUT="${WORK}/checkout"
readonly INDEX_REPO="${WORK}/unipept-index"
readonly STUBS="${WORK}/stubs"
readonly DEPLOY=unipept
readonly DEPLOY_HOME=/home/unipept

export PATH="${STUBS}:${PATH}"

# A checkout of this repository holding the deploy scripts and stand-ins for what they call. The
# real repository is read-only, and the point is to replace the expensive parts.
setup_checkout() {
    rm -rf "${CHECKOUT:?}"
    mkdir -p "${CHECKOUT}"/{.deploy/opensearch,pipelines/lib,pipelines/suffix-array,opensearch,assets}

    cp /repo/.deploy/*.sh "${CHECKOUT}/.deploy/"
    cp /repo/.deploy/opensearch/*.sh "${CHECKOUT}/.deploy/opensearch/"
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

    make_loader "${CHECKOUT}/opensearch/load.sh" /work/loader-calls
    chmod +x "${CHECKOUT}/pipelines/suffix-array/build.sh"

    # Through the configuration file, which is how a host sets this, so the suite covers that path
    # too. It also keeps the run offline: without it build.sh clones unipept-index from GitHub.
    printf 'INDEX_REPO=%s\n' "$INDEX_REPO" > "${CHECKOUT}/.deploy/deploy.conf"

    git -C "$CHECKOUT" init -q
    printf '.deploy/deploy.conf\n' > "${CHECKOUT}/.gitignore"
    commit_all "$CHECKOUT" "the checkout under test"
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
# The remote host is this container, reached as DEPLOY, which is who clone.sh logs in as on a
# real one too.
setup_sshd() {
    mkdir -p /run/sshd
    ssh-keygen -A > /dev/null 2>&1
    /usr/sbin/sshd

    as_deployer mkdir -p "${DEPLOY_HOME}/.ssh"
    as_deployer ssh-keygen -q -t ed25519 -N '' -f "${DEPLOY_HOME}/.ssh/id_test"
    as_deployer cp "${DEPLOY_HOME}/.ssh/id_test.pub" "${DEPLOY_HOME}/.ssh/authorized_keys"

    # clone.sh runs ssh without StrictHostKeyChecking=no, as it does on a real host, so the key has
    # to be known before it runs.
    ssh-keyscan -H localhost 2>/dev/null | as_deployer tee -a "${DEPLOY_HOME}/.ssh/known_hosts" > /dev/null
}

# For check_true, which runs a command rather than evaluating an expression.
not() { ! "$@"; }

# Keeps PATH, so the stand-ins in STUBS come first for DEPLOY too.
as_deployer() {
    runuser -u "$DEPLOY" -- "$@"
}

build() {
    as_deployer "${CHECKOUT}/.deploy/build.sh" "$@" > /work/last-output 2>&1
}

clone() {
    as_deployer "${CHECKOUT}/.deploy/clone.sh" \
        --remote-address localhost --remote-user "$DEPLOY" --remote-port 22 \
        --local-ssh-key "${DEPLOY_HOME}/.ssh/id_test" "$@" > /work/last-output 2>&1
}

mkdir -p "$WORK"
setup_stubs
make_index_repo "$INDEX_REPO" "$WORK"
setup_checkout
# Everything the scripts write lands under WORK, and git refuses a repository another user owns.
chown -R "${DEPLOY}:" "$WORK"
setup_sshd


section "build.sh, clone.sh and verify.sh as root"

"${CHECKOUT}/.deploy/build.sh" --output-dir /work/as-root --scratch-dir /work/scratch > /work/last-output 2>&1
check "build.sh refuses" "$?" "2"
check_true "it names the user to run as" grep -q "Run it as ${DEPLOY}" /work/last-output
check_true "before it writes anything" test ! -e /work/as-root

"${CHECKOUT}/.deploy/clone.sh" --remote-address localhost --local-ssh-key "${DEPLOY_HOME}/.ssh/id_test" \
    --output-dir /work/as-root > /work/last-output 2>&1
check "clone.sh refuses" "$?" "2"
check_true "it names the user to run as" grep -q "Run it as ${DEPLOY}" /work/last-output

"${CHECKOUT}/.deploy/verify.sh" --index-dir /work > /work/last-output 2>&1
check "verify.sh refuses" "$?" "2"
check_true "it names the user to run as" grep -q "Run it as ${DEPLOY}" /work/last-output


section "a clean build"

OUT=/work/data
as_deployer mkdir -p "$OUT"
build --output-dir "$OUT" --scratch-dir /work/scratch --opensearch-url http://stub:9200
check "the build succeeds" "$?" "0"
check_true "the database is named after the version the pipeline wrote" \
    test -d "${OUT}/uniprot-2026-03"
check_true "verify.sh passes on it" \
    as_deployer "${CHECKOUT}/.deploy/verify.sh" --index-dir "${OUT}/uniprot-2026-03/suffix-array"
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
    "$(as_deployer git -C "$CHECKOUT" rev-parse HEAD)"
check "build-info.txt records the index it cloned" \
    "$(grep '^unipept-index:' "${OUT}/uniprot-2026-03/suffix-array/build-info.txt" | awk '{print $2}')" \
    "$(as_deployer git -C "$INDEX_REPO" rev-parse HEAD)"
check "the database belongs to the user the API reads as" \
    "$(find "${OUT}/uniprot-2026-03" ! -user "$DEPLOY" | wc -l)" "0"


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
as_deployer mkdir -p "$EMPTY_OUT"
rm -f /work/loader-calls
build --output-dir "$EMPTY_OUT" --scratch-dir /work/scratch
check "it stops" "$?" "2"
check_true "the empty table is named" grep -q 'datastore/taxons.tsv is empty' /work/last-output
check_true "no database is put in place" test ! -d "${EMPTY_OUT}/uniprot-2026-03"
# The loader drops and recreates the index the API queries, so a refused build must not reach it.
check_true "the proteins OpenSearch serves are left alone" test ! -s /work/loader-calls
as_deployer git -C "$CHECKOUT" checkout -q -- pipelines/suffix-array/build.sh


section "a build whose load fails"

# The load is the last step before the swap, so a load that fails is the latest a build can fail
# and still leave what the API serves alone.
printf '#!/usr/bin/env bash\nexit 1\n' > "${CHECKOUT}/opensearch/load.sh"
printf 'do not lose me\n' > "${OUT}/uniprot-2026-03/marker"
build --output-dir "$OUT" --scratch-dir /work/scratch --replace
check "it stops" "$?" "2"
check_true "the database that was there is kept" test -f "${OUT}/uniprot-2026-03/marker"
check_true "the build is not marked complete" test ! -e "${OUT}/.build/suffix-array/build-info.txt"
as_deployer git -C "$CHECKOUT" checkout -q -- opensearch/load.sh
rm "${OUT}/uniprot-2026-03/marker"


section "cloning over a real ssh and scp"

REMOTE=/work/remote
LOCAL=/work/local
as_deployer mkdir -p "$REMOTE" "$LOCAL"
cp -r "${OUT}/uniprot-2026-03" "${REMOTE}/uniprot-2026-03"
cp -r "${OUT}/uniprot-2026-03" "${REMOTE}/uniprot-2025-11"
printf '2025.11\n' > "${REMOTE}/uniprot-2025-11/suffix-array/.version"
# What an interrupted swap leaves behind on the remote. It sorts after the database it replaced.
cp -r "${OUT}/uniprot-2026-03" "${REMOTE}/uniprot-2026-03.replaced"

rm -f /work/loader-calls
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --opensearch-url http://stub:9200
check "the clone succeeds" "$?" "0"
check "the proteins were loaded once" "$(grep -c -- '--uniprot-entries' /work/loader-calls)" "1"
check_true "from the copy, before it is put in place" \
    grep -qF -- "--opensearch-url http://stub:9200 --uniprot-entries ${LOCAL}/.clone/uniprot-2026-03/tables/uniprot_entries.tsv.lz4" \
    /work/loader-calls
check_true "the newest release on the remote is the one taken" test -d "${LOCAL}/uniprot-2026-03"
check_true "a leftover beside it is not taken for a release" test ! -e "${LOCAL}/uniprot-2026-03.replaced"
check_true "the older one is left alone" test ! -d "${LOCAL}/uniprot-2025-11"
check_true "the copy lands where the script looks for it" \
    test -s "${LOCAL}/uniprot-2026-03/suffix-array/sa.bin"
check_true "verify.sh passes on the copy" \
    as_deployer "${CHECKOUT}/.deploy/verify.sh" --index-dir "${LOCAL}/uniprot-2026-03/suffix-array"
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

clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL"
check "a version that is already here stops" "$?" "2"
check_true "it says how to replace it" grep -q -- '--replace' /work/last-output
check_true "it stops before copying anything" test ! -e "${LOCAL}/.clone"

printf '#!/usr/bin/env bash\nexit 1\n' > "${CHECKOUT}/opensearch/load.sh"
printf 'do not lose me\n' > "${LOCAL}/uniprot-2026-03/marker"
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --replace
check "a load that fails stops the clone" "$?" "2"
check_true "the database that was there is kept" test -f "${LOCAL}/uniprot-2026-03/marker"
as_deployer git -C "$CHECKOUT" checkout -q -- opensearch/load.sh
rm "${LOCAL}/uniprot-2026-03/marker"

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

# An ssh that fails when asked about the k-mer table, after the copy. That says nothing about the
# table, so it must not read as a remote without one.
cat > "${STUBS}/ssh" <<'SSH'
#!/usr/bin/env bash
case "$*" in *kmer_table.bin*) exit 255 ;; esac
exec /usr/bin/ssh "$@"
SSH
chmod +x "${STUBS}/ssh"
printf 'do not lose me\n' > "${LOCAL}/uniprot-2026-03/marker"
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --replace
check "an ssh that fails on the k-mer question stops it" "$?" "2"
check_true "it says it could not ask" grep -q 'could not ask localhost whether it has a k-mer table' /work/last-output
check_true "the database that was there is kept" test -f "${LOCAL}/uniprot-2026-03/marker"
rm "${STUBS}/ssh" "${LOCAL}/uniprot-2026-03/marker"

rm "${REMOTE}/uniprot-2026-03/suffix-array/mapping.bin"
rm -rf "${LOCAL}/uniprot-2026-03" "${LOCAL}/.clone"
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL"
check "an incomplete database on the remote stops" "$?" "2"
check_true "the missing file is named" grep -q 'mapping.bin is missing' /work/last-output
check_true "it stops before copying anything" test ! -e "${LOCAL}/.clone"
check_true "nothing is put in place" test ! -d "${LOCAL}/uniprot-2026-03"

# The version check runs on the remote through the functions clone.sh sends along, so this is what
# fails if one it needs is not sent.
printf '2024.01\n' > "${REMOTE}/uniprot-2025-11/suffix-array/.version"
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --uniprot-version 2025-11 --replace
check "a remote database whose .version disagrees with its name stops" "$?" "2"
check_true "both versions are named" grep -q 'the directory says 2025-11 and .version says 2024-01' /work/last-output
check_true "it stops before copying anything" test ! -e "${LOCAL}/.clone"
check "the copy already here is kept" "$(cat "${LOCAL}/uniprot-2025-11/suffix-array/.version")" "2025.11"
printf '2025.11\n' > "${REMOTE}/uniprot-2025-11/suffix-array/.version"

rm "${REMOTE}/uniprot-2025-11/tables/uniprot_entries.tsv.lz4"
clone --remote-output-dir "$REMOTE" --output-dir "$LOCAL" --uniprot-version 2025-11 --replace
check "a remote database without its entries table stops" "$?" "2"
check_true "the table is named" grep -q 'tables/uniprot_entries.tsv.lz4 is missing' /work/last-output
check_true "it stops before copying anything" test ! -e "${LOCAL}/.clone"


# install.sh, against stand-ins for apt, dpkg, systemd and the instance itself. What is real is the
# script and the files it writes under /etc/opensearch, which this container is free to change.
readonly INSTALL_STUBS="${WORK}/install-stubs"
readonly DPKG_STATE="${WORK}/dpkg-state"
readonly CONFIG=/etc/opensearch/opensearch.yml
readonly HEAP=/etc/opensearch/jvm.options.d/heap.options

setup_install_stubs() {
    mkdir -p "$INSTALL_STUBS"

    # What dpkg knows: OpenSearch's status and version as a "status version" line in dpkg-state, and
    # every other package installed as a line in dpkg-installed. Nothing when it never was. Answers
    # in the format it is asked for, as dpkg-query does.
    cat > "${INSTALL_STUBS}/dpkg-query" <<'STUB'
#!/usr/bin/env bash
package="${*: -1}"
if [ "$package" = opensearch ]; then
    [ -s /work/dpkg-state ] || exit 1
    read -r status version < /work/dpkg-state
else
    grep -qx -- "$package" /work/dpkg-installed 2> /dev/null || exit 1
    status=installed version=1
fi
format="${1#--showformat=}"
format="${format//'${db:Status-Status}'/$status}"
printf '%s' "${format//'${Version}'/$version}"
STUB
    cat > "${INSTALL_STUBS}/apt-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> /work/apt-calls
[ "$1" = install ] || exit 0
for arg in "${@:2}"; do
    case "$arg" in
        -*) ;;
        opensearch=*) echo "installed ${arg#opensearch=}" > /work/dpkg-state ;;
        *) echo "$arg" >> /work/dpkg-installed ;;
    esac
done
STUB
    cat > "${INSTALL_STUBS}/apt-mark" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${WORK}/apt-calls"
STUB
    cat > "${INSTALL_STUBS}/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${WORK}/systemctl-calls"
case "\$1" in
    is-active) [ -e "${WORK}/opensearch-active" ] ;;
    restart) touch "${WORK}/opensearch-active" ;;
esac
STUB
    # The instance: records each request, and answers at once unless curl-fails is there.
    cat > "${INSTALL_STUBS}/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${WORK}/curl-calls"
[ ! -e "${WORK}/curl-fails" ] || exit 7
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "${INSTALL_STUBS}/gpg"
    chmod +x "${INSTALL_STUBS}"/*

    # The repository is already configured, so add_repository has nothing to fetch.
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    touch /usr/share/keyrings/opensearch-keyring.gpg /etc/apt/sources.list.d/opensearch-2.x.list
}

# A host as the package leaves it: its own configuration, naming its own data and log paths.
packaged_host() {
    rm -rf /etc/opensearch "${WORK}"/{apt-calls,systemctl-calls,curl-calls,opensearch-active} "$DPKG_STATE"
    mkdir -p /etc/opensearch /var/lib/opensearch /var/log/opensearch
    printf 'cluster.name: my-application\npath.data: /var/lib/opensearch\npath.logs: /var/log/opensearch\n' > "$CONFIG"
}

forget_calls() {
    rm -f "${WORK}"/{apt-calls,systemctl-calls,curl-calls}
    touch "${WORK}"/{apt-calls,systemctl-calls,curl-calls}
}

install_opensearch() {
    PATH="${INSTALL_STUBS}:${PATH}" "${CHECKOUT}/.deploy/opensearch/install.sh" "$@" > /work/last-output 2>&1
}

setup_install_stubs


section "install.sh on a fresh host"

packaged_host
forget_calls
install_opensearch
check "it succeeds" "$?" "0"
check_true "the pinned version is installed" grep -q 'install .*opensearch=2.19.0' /work/apt-calls
check_true "and held" grep -qx 'hold opensearch' /work/apt-calls
check_true "the tools build.sh and clone.sh use are installed" grep -q 'install .*python3-requests' /work/apt-calls
check_true "the packaged configuration is kept" grep -q 'my-application' "${CONFIG}.dist"
check_true "the data path the package set is kept" grep -qx 'path.data: /var/lib/opensearch' "$CONFIG"
check_true "and the log path" grep -qx 'path.logs: /var/log/opensearch' "$CONFIG"
check_true "the heap defaults to 4g" grep -qx -- '-Xmx4g' "$HEAP"
check_true "the service is restarted" grep -qx 'restart opensearch' /work/systemctl-calls
check_true "it waits on the address it configured" grep -qF 'http://127.0.0.1:9200/_cluster/health' /work/curl-calls
check_true "new indices default to no replica" grep -qF '"cluster.default_number_of_replicas":0' /work/curl-calls
check_true "the plugin's replicated indices are not written" grep -qF '"search.insights.top_queries.exporter.type":"none"' /work/curl-calls
check_true "the indices already there lose theirs" grep -qF '/_all/_settings?expand_wildcards=all' /work/curl-calls


section "install.sh a second time"

cp "$CONFIG" /work/config-before
forget_calls
install_opensearch
check "it succeeds" "$?" "0"
check_true "nothing is installed" not grep -q 'install' /work/apt-calls
check_true "the configuration is unchanged" cmp -s "$CONFIG" /work/config-before
check_true "the running service is not restarted" not grep -q 'restart' /work/systemctl-calls


section "install.sh where the service is down"

rm -f "${WORK}/opensearch-active"
forget_calls
install_opensearch
check "it succeeds" "$?" "0"
check_true "the service is started, though nothing changed" grep -qx 'restart opensearch' /work/systemctl-calls

touch "${WORK}/curl-fails"
forget_calls
install_opensearch
check "an instance that does not answer stops it" "$?" "2"
check_true "it says where it waited and where to look" \
    grep -q 'did not answer at http://127.0.0.1:9200 .* journalctl -u opensearch' /work/last-output
check_true "it sets nothing on an instance that is not there" not grep -q '_settings' /work/curl-calls
rm "${WORK}/curl-fails"


section "install.sh keeps the heap a host was given"

forget_calls
install_opensearch --heap 8g
check "--heap succeeds" "$?" "0"
check_true "the heap is 8g" grep -qx -- '-Xmx8g' "$HEAP"
check_true "the change restarts the service" grep -qx 'restart opensearch' /work/systemctl-calls

forget_calls
install_opensearch
check "a run without --heap succeeds" "$?" "0"
check_true "the heap is still 8g" grep -qx -- '-Xmx8g' "$HEAP"
check_true "nothing is restarted" not grep -q 'restart' /work/systemctl-calls


section "install.sh on a host set up by hand"

packaged_host
mkdir -p /work/hand/data /work/hand/logs
printf 'cluster.name: by-hand\npath.data: /work/hand/data\npath.logs: /work/hand/logs\n' > "$CONFIG"
echo "installed 2.19.0" > "$DPKG_STATE"
touch "${WORK}/opensearch-active"
forget_calls
install_opensearch
check "it succeeds" "$?" "0"
check_true "nothing is installed" not grep -q 'install' /work/apt-calls
check_true "the version it already has is held" grep -qx 'hold opensearch' /work/apt-calls
check_true "its data path is kept" grep -qx 'path.data: /work/hand/data' "$CONFIG"
check_true "and its log path" grep -qx 'path.logs: /work/hand/logs' "$CONFIG"

packaged_host
printf 'path.data: /work/no-such-volume\n' > "$CONFIG"
cp "$CONFIG" /work/config-before
install_opensearch
check "a data path that is not there stops it" "$?" "2"
check_true "the path is named" grep -q '/work/no-such-volume' /work/last-output
check_true "the configuration is left as it was" cmp -s "$CONFIG" /work/config-before


section "install.sh where the package was removed and not purged"

packaged_host
echo "config-files 2.18.0" > "$DPKG_STATE"
forget_calls
install_opensearch
check "it installs rather than stopping" "$?" "0"
check_true "the pinned version is installed" grep -q 'install .*opensearch=2.19.0' /work/apt-calls


section "install.sh where another version is installed"

packaged_host
echo "installed 2.18.0" > "$DPKG_STATE"
cp "$CONFIG" /work/config-before
forget_calls
install_opensearch
check "it stops" "$?" "2"
check_true "it names both versions" grep -q 'OpenSearch 2.18.0 is installed and this script pins 2.19.0' /work/last-output
check_true "it installs nothing over it" not grep -q 'install .*opensearch=' /work/apt-calls
check_true "the configuration is left as it was" cmp -s "$CONFIG" /work/config-before
check_true "the service is not touched" not grep -q 'restart' /work/systemctl-calls


section "install.sh waits where the instance listens"

packaged_host
forget_calls
install_opensearch --bind 10.0.0.5 --port 9201
check "it succeeds" "$?" "0"
check_true "the port is configured" grep -qx 'http.port: 9201' "$CONFIG"
check_true "it waits on the bind address and port" grep -qF 'http://10.0.0.5:9201/_cluster/health' /work/curl-calls
check_true "and sets the cluster there" grep -qF 'http://10.0.0.5:9201/_cluster/settings' /work/curl-calls

forget_calls
install_opensearch --bind 0.0.0.0
check "a wildcard bind succeeds" "$?" "0"
check_true "it waits on the loopback address" grep -qF 'http://127.0.0.1:9200/_cluster/health' /work/curl-calls


section "install.sh prepares the user the databases belong to"

packaged_host
forget_calls
install_opensearch --user deployer2 --output-dir /work/out2
check "it succeeds" "$?" "0"
check_true "the user is created" id deployer2
check "with a login shell, for ssh" "$(getent passwd deployer2 | cut -d: -f7)" "/bin/bash"
check "the output directory is theirs" "$(stat -c %U /work/out2)" "deployer2"
check_true "tools already there are not installed again" not grep -q 'install .*python3-requests' /work/apt-calls

useradd --shell /usr/sbin/nologin deployer3
install_opensearch --user deployer3 --output-dir /work/out3
check "an account without a shell succeeds" "$?" "0"
check "it is given one" "$(getent passwd deployer3 | cut -d: -f7)" "/bin/bash"

# What a run of build.sh as root left, beside what OUTPUT_DIR also holds and is not this script's.
# The .replaced is what an interrupted swap leaves: the next swap removes it first, and as DEPLOY
# could not while root owned what is in it.
mkdir -p /work/out4/uniprot-2026-03/suffix-array /work/out4/uniprot-2025-11.replaced/suffix-array \
    /work/out4/.build /work/out4/.clone /work/out4/opensearch-data
touch /work/out4/uniprot-2026-03/suffix-array/sa.bin /work/out4/uniprot-2025-11.replaced/suffix-array/sa.bin \
    /work/out4/opensearch-data/node
install_opensearch --user "$DEPLOY" --output-dir /work/out4
check "an output directory root owns succeeds" "$?" "0"
check "it is handed over" "$(stat -c %U /work/out4)" "$DEPLOY"
check "and the database in it" "$(stat -c %U /work/out4/uniprot-2026-03/suffix-array/sa.bin)" "$DEPLOY"
check "and the staging directories" "$(stat -c %U /work/out4/.build):$(stat -c %U /work/out4/.clone)" "${DEPLOY}:${DEPLOY}"
check "and what an interrupted swap left" \
    "$(stat -c %U /work/out4/uniprot-2025-11.replaced/suffix-array/sa.bin)" "$DEPLOY"
check "what else is there keeps its owner" "$(stat -c %U /work/out4/opensearch-data/node)" "root"
check_true "it says what is left to do as that user" grep -q "as ${DEPLOY} (sudo -iu ${DEPLOY})" /work/last-output


summary
