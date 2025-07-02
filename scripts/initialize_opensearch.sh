#! /usr/bin/env bash

set -eo pipefail

# This script expects an OpenSearch instance to be active on this machine. It will then drop all existing indices,
# recreate them according to the current versions of these indices and then import all proteins.


# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

################################################################################
#                                    Imports                                   #
################################################################################

source "${CURRENT_LOCATION}/general_helpers.sh"

################################################################################
#                            Variables and options                             #
################################################################################

# URL used to communicate with a running OpenSearch instance
OPENSEARCH_URL="http://localhost:9200"

# TSV-file containing the UniProt entries that should be uploaded and indexed
UNIPROT_ENTRIES_FILE=""

# The amount of documents that are uploaded at once to the OpenSearch instance
UPLOAD_BATCH_SIZE=2500

################################################################################
#                            Helper Functions                                  #
################################################################################

################################################################################
# terminateAndExit                                                             #
#                                                                              #
# Stops the script and removes all temporary files that are created by this    #
# script. Prints an error message to stderr and exits with status code 1.      #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr                                                   #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
terminateAndExit() {
	echo "Error: execution of the script was cancelled by the user." 1>&2
	echo ""
	exit 1
}

################################################################################
# errorAndExit                                                                 #
#                                                                              #
# Can be called when an error has occurred during the execution of the script. #
# This function will inform the user of what error occurred, where it occurred,#
# and what command was being executed when it happened. It will then properly  #
# exit the script, cleaning up any temporary files first.                      #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 (optional)     - Additional error message to display                    #
#                                                                              #
# Outputs:                                                                     #
#   Error details to stderr                                                    #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 2                                                  #
################################################################################
errorAndExit() {
    local exit_status="$?"        # Capture the exit status of the last command
    local line_no=${BASH_LINENO[0]}  # Get the line number where the error occurred
    local command="${BASH_COMMAND}"  # Get the command that was executed

    echo "Error: the script experienced an error while trying to build the requested database." 1>&2
    echo "Error details:" 1>&2
    echo "Command '$command' failed with exit status $exit_status at line $line_no." 1>&2

    if [[ -n "$1" ]]
    then
        echo "$1" 1>&2
    fi

    echo "" 1>&2
    exit 2
}

trap terminateAndExit SIGINT
trap errorAndExit ERR

################################################################################
#                               Main functions                                 #
################################################################################

################################################################################
# init_indices                                                                 #
#                                                                              #
# Clears old indices in the OpenSearch instance and recreates them using the   #
# latest index definitions to ensure they are up-to-date. It fetches a list of #
# the current indices, deletes them, and recreates the "uniprot_entries" index #
# using its JSON definition file.                                              #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
init_indices() {
    log "Started dropping existing indices."

    # Check if OpenSearch is up
    if ! curl -s -f "${OPENSEARCH_URL}/_cluster/health" > /dev/null; then
        echo "OpenSearch is not reachable. Attempting to start it via systemctl..."

        sudo systemctl start opensearch

        # Wait a few seconds for OpenSearch to start
        sleep 20

        if ! curl -s -f "${OPENSEARCH_URL}/_cluster/health" > /dev/null; then
            echo "Failed to connect to OpenSearch after attempting to start it."
            exit 1
        else
            echo "OpenSearch successfully started."
        fi
    else
        echo "OpenSearch is already running."
    fi

    # Fetch the list of all current indices from the OpenSearch instance
    local indices
    indices=$(curl -s -X GET "${OPENSEARCH_URL}/_cat/indices?h=index")
    local curl_exit=$?

    if [[ $curl_exit -ne 0 ]]; then
        echo "Failed to fetch indices"
        exit 1
    fi

    # Iterate through each index and delete it
    # Check if any indices were returned
    if [[ -n "$indices" ]]; then
        # Iterate through each index and delete it
        for index in $indices; do
            echo "Deleting index: $index"
            curl -s -X DELETE "${OPENSEARCH_URL}/${index}" > /dev/null || { echo "Failed to delete index: $index"; exit 1; }
        done
    else
        echo "No indices found to delete."
    fi

    echo "Finished dropping existing indices."

    log "Started creating new indices."

    # All indexes are defined in separate JSON-files
    local uniprot_entries_index_file="${CURRENT_LOCATION}/../schemas_suffix_array/index_uniprot_entries.json"

    # Use the JSON file pointed to by the variable to create the new index
    if [[ -f "${uniprot_entries_index_file}" ]]; then
        curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries" -H 'Content-Type: application/json' -d @"${uniprot_entries_index_file}" > /dev/null || { echo "Failed to create uniprot_entries index"; exit 1; }
        echo "Successfully created uniprot_entries index."
    else
        echo "Index file ${uniprot_entries_index_file} does not exist."
        exit 1
    fi

    log "Finished creating new indices."
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

    pv "$UNIPROT_ENTRIES_FILE" | lz4cat | cut -f 2-8 | python3 "${CURRENT_LOCATION}/upload_to_opensearch.py" --index-name "uniprot_entries" --fields "uniprot_accession_number,version,taxon_id,type,name,sequence,fa" --id-field "uniprot_accession_number"

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
    if [[ -z $UNIPROT_ENTRIES_FILE ]]; then
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
    echo "  --help              Prints this help message."
    echo ""
    echo "Examples:"
    echo "  $0 --uniprot-entries /path/to/uniprot_entries.tsv.lz4"
    echo "  $0 --opensearch-url http://localhost:9200 --uniprot-entries /path/to/uniprot_entries.tsv.lz4"
    echo ""
}

# Check if all required dependencies are installed
checkdep "lz4"

parse_arguments "$@"
init_indices
upload_uniprot_entries
