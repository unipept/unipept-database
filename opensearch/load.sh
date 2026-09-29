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

################################################################################
# parse_arguments                                                              #
#                                                                              #
# Parses command-line arguments provided to the script and sets options and    #
# variables accordingly. Ensures required parameters are set and prints the    #
# help message if invalid or missing arguments are provided.                   #
#                                                                              #
# Arguments:                                                                   #
#   --opensearch-url      (optional) URL of the OpenSearch instance. Defaults  #
#                         to 'http://localhost:9200'.                         #
#   --uniprot-entries     (required) Path to the UniProt TSV file for upload.  #
#   --index-name          (optional) The index to fill. Defaults to            #
#                         'uniprot_entries'.                                   #
#   --skip                Rows to pass over, keeping the index.                #
#   --check-complete      Loads nothing; exits 0 if --index-name was loaded    #
#                         to the end, 1 otherwise.                             #
#   --help                Prints the help message and exits.                   #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --opensearch-url)
                OPENSEARCH_URL="$2"
                shift 2
                ;;
            --uniprot-entries)
                UNIPROT_ENTRIES_FILE="$2"
                shift 2
                ;;
            --index-name)
                INDEX_NAME="$2"
                if ! [[ "$INDEX_NAME" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
                    echo "Error: --index-name takes a lowercase OpenSearch index name."
                    print_help
                    exit 1
                fi
                shift 2
                ;;
            --check-complete)
                CHECK_COMPLETE=true
                shift
                ;;
            --skip)
                SKIP_ROWS="$2"
                if ! [[ "$SKIP_ROWS" =~ ^[0-9]+$ ]]; then
                    echo "Error: --skip takes a number of rows."
                    print_help
                    exit 1
                fi
                shift 2
                ;;
            --help)
                print_help
                exit 0
                ;;
            *)
                echo "Unknown parameter: $1"
                print_help
                exit 1
                ;;
        esac
    done

    # Ensure the required parameter --uniprot-entries is set
    if [[ -z $UNIPROT_ENTRIES_FILE && "$CHECK_COMPLETE" != true ]]; then
        echo "Error: --uniprot-entries is required."
        print_help
        exit 1
    fi
}

################################################################################
# print_help                                                                   #
#                                                                              #
# Displays a help message that describes the script usage, parameters, and     #
# examples of how to execute it. This message is printed when the '--help'     #
# flag is passed or when invalid arguments are provided to the script.         #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --uniprot-entries   Path to the 'uniprot_entries.tsv.lz4' file to be uploaded (required)."
    echo "  --opensearch-url    URL to communicate with the running OpenSearch instance (optional, default: 'http://localhost:9200')."
    echo "  --index-name        The index to drop, create and fill (optional, default: 'uniprot_entries')."
    echo "  --skip              Rows to pass over, to continue an upload that stopped part way. The index is kept."
    echo "  --check-complete    Load nothing: exit 0 if the index was loaded to the end, 1 if not."
    echo "  --help              Prints this help message."
    echo ""
    echo "Examples:"
    echo "  $0 --uniprot-entries /path/to/uniprot_entries.tsv.lz4"
    echo "  $0 --opensearch-url http://localhost:9200 --uniprot-entries /path/to/uniprot_entries.tsv.lz4"
    echo ""
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
