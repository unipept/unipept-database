#! /usr/bin/env bash

set -eo pipefail

# Drops and recreates one index on a running OpenSearch instance, uniprot_entries unless
# --index-name says otherwise, then imports the proteins into it. Other indices on the instance are
# not touched. .deploy/load.sh names the index after the version, and refuses the one this host
# serves.


# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

################################################################################
#                                    Imports                                   #
################################################################################

source "${CURRENT_LOCATION}/../pipelines/lib/common.sh"
source "${CURRENT_LOCATION}/lib.sh"

################################################################################
#                            Variables and options                             #
################################################################################

# URL used to communicate with a running OpenSearch instance
OPENSEARCH_URL="http://localhost:9200"

# TSV-file containing the UniProt entries that should be uploaded and indexed
UNIPROT_ENTRIES_FILE=""

# The amount of documents that are uploaded at once to the OpenSearch instance
UPLOAD_BATCH_SIZE=2500

# The index this script drops, creates and fills. Nothing else on the instance is touched.
INDEX_NAME="uniprot_entries"

# The mapping every index here is created from.
readonly MAPPING_FILE="${CURRENT_LOCATION}/mappings/uniprot_entries.json"

# Whether to only answer if INDEX_NAME was loaded to the end, rather than load anything.
CHECK_COMPLETE=false

# Rows to pass over, to continue an upload that stopped part way. Above zero the index is kept as
# it is, because dropping it would discard the rows being skipped.
SKIP_ROWS=0

################################################################################
#                            Helper Functions                                  #
################################################################################

trap terminateAndExit SIGINT
trap errorAndExit ERR

################################################################################
#                               Main functions                                 #
################################################################################

################################################################################
# init_indices                                                                 #
#                                                                              #
# Drops INDEX_NAME and recreates it from the mapping file.                    #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
init_indices() {
    require_opensearch

    log "Started dropping the ${INDEX_NAME} index."

    # Only this index. The instance is allowed to hold indices that belong to something else.
    # 404 is a success: on a first run there is nothing to drop.
    opensearch_request "dropping the ${INDEX_NAME} index" "200 404" DELETE "${INDEX_NAME}" > /dev/null

    log "Finished dropping the ${INDEX_NAME} index."

    log "Started creating the ${INDEX_NAME} index."

    if [[ ! -f "${MAPPING_FILE}" ]]
    then
        echo "Error: the index definition ${MAPPING_FILE} does not exist." 1>&2
        exit 1
    fi

    opensearch_request "creating the ${INDEX_NAME} index" "200" PUT "${INDEX_NAME}" \
        -H 'Content-Type: application/json' -d @"${MAPPING_FILE}" > /dev/null

    log "Finished creating the ${INDEX_NAME} index."
}

################################################################################
# upload_uniprot_entries                                                       #
#                                                                              #
# Reads the UniProt entries file provided to the script in TSV format,         #
# converts each line to JSON, and uploads them to the OpenSearch instance in   #
# bulk. The function uploads the data in batches and provides real-time        #
# progress updates.                                                            #
#                                                                              #
# Input:                                                                       #
#   - TSV-formatted file specified by the UNIPROT_ENTRIES_FILE variable.       #
#   - Uses the UPLOAD_BATCH_SIZE variable to determine batch size.             #
#                                                                              #
# Output:                                                                      #
#   - Progress updates during the upload process printed to stdout.            #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
upload_uniprot_entries() {
    log "Started uploading UniProt entries."

    pv "$UNIPROT_ENTRIES_FILE" | lz4cat | cut -f 2-8 | python3 "${CURRENT_LOCATION}/bulk_load.py" \
        --opensearch-url "$OPENSEARCH_URL" \
        --index-name "$INDEX_NAME" \
        --fields "uniprot_accession_number,version,taxon_id,type,name,sequence,fa" \
        --id-field "uniprot_accession_number" \
        --batch-size "$UPLOAD_BATCH_SIZE" \
        --skip "$SKIP_ROWS"

    log "Finished uploading UniProt entries."
}

usage() {
    cat <<'USAGE'
Drops and recreates one index on a running OpenSearch, then loads the proteins of a database into
it. .deploy/load.sh runs this, naming the index after the version.

  opensearch/load.sh --uniprot-entries FILE [OPTIONS]

  --uniprot-entries FILE     the uniprot_entries.tsv.lz4 to load, required unless --check-complete
  --index-name NAME          the index to drop, create and fill, default uniprot_entries
  --skip ROWS                continue a load that stopped part way, passing over this many rows;
                             the index is kept
  --check-complete           load nothing: exit 0 if the index is loaded to the end, 1 if not
  --opensearch-url URL       the OpenSearch instance, default http://localhost:9200
  --help                     print this message
USAGE
}

# The value after an option, refused when it is missing or is the next option.
option_value() {
    { [ -n "${2-}" ] && [[ "$2" != --* ]]; } || opensearch_fail "$1 requires a value."
}

# Sets the options above from the arguments. Not with need_value and unknown_option from
# .deploy/lib/core.sh: this script loads the pipelines' library, not .deploy/lib.sh, but its --help
# and its errors read the same way.
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uniprot-entries) option_value "$1" "${2-}"; UNIPROT_ENTRIES_FILE="$2"; shift 2 ;;
            --index-name) option_value "$1" "${2-}"; INDEX_NAME="$2"; shift 2 ;;
            --skip) option_value "$1" "${2-}"; SKIP_ROWS="$2"; shift 2 ;;
            --check-complete) CHECK_COMPLETE=true; shift ;;
            --opensearch-url) option_value "$1" "${2-}"; OPENSEARCH_URL="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) opensearch_fail "unknown option '$1'. Run with --help for the options." ;;
        esac
    done

    [[ "$INDEX_NAME" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] \
        || opensearch_fail "--index-name takes a lowercase OpenSearch index name, not '${INDEX_NAME}'."
    [[ "$SKIP_ROWS" =~ ^[0-9]+$ ]] || opensearch_fail "--skip takes a number of rows, not '${SKIP_ROWS}'."
    [ -n "$UNIPROT_ENTRIES_FILE" ] || [ "$CHECK_COMPLETE" = true ] \
        || opensearch_fail "--uniprot-entries is required."
}

parse_arguments "$@"

# Only curl, so before the loader's own dependencies, which a host that only asks need not have.
if [[ "$CHECK_COMPLETE" == true ]]
then
    is_complete "$INDEX_NAME" && exit 0
    exit 1
fi

# Check if all required dependencies are installed
checkdep "lz4"
checkdep "pv"

checkdep "python3"

if ! python3 -c "import requests" > /dev/null 2>&1
then
    echo "This script requires the requests package: apt install python3-requests on Ubuntu, or pip install -r ${CURRENT_LOCATION}/requirements.txt inside a virtual environment" >&2
    exit 6
fi

if [[ "$SKIP_ROWS" -eq 0 ]]
then
    init_indices
else
    # Written into an index that is not there, the rows would create one with no mapping, holding
    # only the tail, and the mark would then call it whole.
    require_opensearch
    [[ -n "$(index_status "$INDEX_NAME")" ]] \
        || opensearch_fail "there is no ${INDEX_NAME} to continue. Load it from the start, without --skip."
    log "Continuing at row ${SKIP_ROWS}. The ${INDEX_NAME} index is kept as it is."
fi

upload_uniprot_entries
# Last, so an upload that fails leaves the index unmarked.
mark_complete "$INDEX_NAME"
