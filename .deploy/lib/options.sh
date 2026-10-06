# shellcheck shell=bash
#
# The options more than one script takes: --output-dir, --opensearch-url and --uniprot-version.
# Each script parses its own arguments, naming in its own case arms the shared options it takes,
# and hands their values here, so each is checked the same way in every script. Uses die and
# need_value from core.sh and valid_version from versions.sh. Sourced through .deploy/lib.sh.

# Sets the setting a shared option names, given the option and the value after it, for the caller to
# shift both. Stops on a value that is missing, or that is not a UniProtKB version.
shared_option() {
    need_value "$1" "${2-}"
    # shellcheck disable=SC2034 # read by the script that called this
    case $1 in
        --output-dir) OUTPUT_DIR=$2 ;;
        --opensearch-url) OPENSEARCH_URL=$2 ;;
        --uniprot-version) valid_version "$2"; UNIPROT_VERSION=$2 ;;
        *) die "shared_option does not take ${1}." ;;
    esac
}

# Stops on an option the script does not take.
unknown_option() {
    die "unknown option '$1'. Run with --help for the options."
}
