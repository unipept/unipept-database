# shellcheck shell=bash
#
# The stand-in the build suite puts where build-index.sh expects sa-builder. Sourced, never run, and
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
