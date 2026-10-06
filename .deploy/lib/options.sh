# shellcheck shell=bash
#
# The options more than one script takes: --output-dir, --opensearch-url, --uniprot-version and
# --help. A script lists the ones it takes in SHARED_OPTIONS, handles its own options in its own
# parse_arguments, and hands everything else to shared_option. --help is every script's, and needs
# no listing. Uses die and need_value from core.sh, valid_version from versions.sh, and the
# script's own usage for --help. Sourced through .deploy/lib.sh.

# What each shared option takes, and what it says in --help. A script whose --uniprot-version means
# something more particular, as switch.sh's does, sets its own text here before usage runs.
declare -A OPTION_VALUE=(
    [--output-dir]=DIR
    [--opensearch-url]=URL
    [--uniprot-version]=YYYY-MM
)
declare -A OPTION_HELP=(
    [--output-dir]="where the databases are, one directory per version"
    [--opensearch-url]="the OpenSearch instance their proteins are loaded into"
    [--uniprot-version]="which database, as YYYY-MM"
)

# The shared options this script takes, in the order --help lists them.
SHARED_OPTIONS=()

# Handles the option at the front of the arguments, given all of them, and sets SHIFTED to how many
# it used, for the caller to shift. Stops on an option the script does not take, and on a value
# that is missing or not a UniProtKB version.
shared_option() {
    local option=$1

    if [ "$option" = --help ]; then
        usage
        exit 0
    fi
    case " ${SHARED_OPTIONS[*]} " in
        *" ${option} "*) ;;
        *) die "unknown option '${option}'. Run with --help for the options." ;;
    esac

    need_value "$option" "${2-}"
    # shellcheck disable=SC2034 # read by the script that called this
    case $option in
        --output-dir) OUTPUT_DIR=$2 ;;
        --opensearch-url) OPENSEARCH_URL=$2 ;;
        --uniprot-version) valid_version "$2"; UNIPROT_VERSION=$2 ;;
    esac
    # shellcheck disable=SC2034 # read by the script that called this
    SHIFTED=2
}

# The --help lines for SHARED_OPTIONS and --help, in the column every script's own lines use: the
# option at two spaces, its text at thirty.
shared_usage() {
    local option

    for option in "${SHARED_OPTIONS[@]}"; do
        option_line "${option} ${OPTION_VALUE[$option]}" "${OPTION_HELP[$option]}"
    done
    option_line --help "print this message"
}

# The last lines of every script's --help: which of its settings wins.
precedence_note() {
    printf '\n%s\n' "A flag wins over deploy.conf, which wins over the defaults in lib/ and in the script."
}

# One --help line: the option with its value, and what it does. A script's own lines that run on
# continue at the same thirtieth column.
option_line() { printf '  %-26s %s\n' "$1" "$2"; }
