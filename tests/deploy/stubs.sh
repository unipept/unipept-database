# shellcheck shell=bash
#
# The stand-ins the suites put where build-index.sh expects sa-builder and load.sh expects the
# OpenSearch loader.
# One copy, so a new flag build-index.sh passes is taught to every suite at once. Sourced, never run, and
# after tests/lib.sh.

# A stand-in sa-builder: it writes each output it is asked for, keeps the protein file it was
# handed and records its call. It exits with SA_BUILDER_STATUS.
make_sa_builder() {
    local target="$1" given="$2" calls="$3"

    cat > "$target" <<SA
#!/usr/bin/env bash
set -eo pipefail
prev=''
for arg in "\$@"; do
    case "\$prev" in
        --database-file) cat "\$arg" > "${given}" ;;
        --output-sa | --output-proteins | --output-mapping | --output-kmer-table)
            printf 'binary\\n' > "\$arg" ;;
    esac
    prev="\$arg"
done
printf '%s\\n' "\$*" >> "${calls}"
exit "\${SA_BUILDER_STATUS:-0}"
SA
    chmod +x "$target"
}

# A repository build.sh clones for sa-builder, over a path rather than the network, so clone_repo
# and the commit it records are the real ones. It holds a crate cargo can really build, for the
# suite that runs the real cargo, beside a committed sa-builder that is what actually runs: it
# writes each output it is asked for, keeps the protein file it was handed, and records its call.
make_index_repo() {
    local repo="$1" work="$2"

    rm -rf "${repo:?}"
    mkdir -p "${repo}/target/release" "${repo}/src"
    printf '[package]\nname = "stand-in"\nversion = "0.0.0"\nedition = "2021"\n' > "${repo}/Cargo.toml"
    printf 'fn main() {}\n' > "${repo}/src/main.rs"

    make_sa_builder "${repo}/target/release/sa-builder" "${work}/proteins-given-to-sa-builder.tsv" \
        "${work}/sa-builder-calls"

    git -C "$repo" init -q
    commit_all "$repo" "stand-in index"
}

# The OpenSearch loader: records each call and what it was given. tests/run-tests.sh opensearch
# covers the real one against a real OpenSearch.
make_loader() {
    local target="$1" calls="$2"

    mkdir -p "$(dirname "$target")"
    cat > "$target" <<LOADER
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "\$*" >> "${calls}"
LOADER
    chmod +x "$target"
}
