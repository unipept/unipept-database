# shellcheck shell=bash
#
# The stand-ins both deploy suites put where build.sh expects sa-builder and the OpenSearch loader.
# One copy, so a new flag build.sh passes is taught to both suites at once. Sourced, never run, and
# after tests/lib.sh.

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

    cat > "${repo}/target/release/sa-builder" <<SA
#!/usr/bin/env bash
set -eo pipefail
prev=''
for arg in "\$@"; do
    case "\$prev" in
        --database-file) cp "\$arg" "${work}/proteins-given-to-sa-builder.tsv" ;;
        --output-sa | --output-proteins | --output-mapping | --output-kmer-table)
            printf 'binary\n' > "\$arg" ;;
    esac
    prev="\$arg"
done
printf '%s\n' "\$*" >> "${work}/sa-builder-calls"
SA
    chmod +x "${repo}/target/release/sa-builder"

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
