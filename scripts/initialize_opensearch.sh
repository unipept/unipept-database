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
UPLOAD_BATCH_SIZE=1000

################################################################################
#                               Main functions                                 #
################################################################################

# Clear old indices in the OpenSearch instance, and create the new indices according to the current requirements.
init_indices() {
    log "Started dropping existing indices."

    # Fetch the list of all current indices from the OpenSearch instance
    local indices=$(curl -s -X GET "${OPENSEARCH_URL}/_cat/indices?h=index" || { echo "Failed to fetch indices"; exit 1; })

    # Iterate through each index and delete it
    for index in $indices; do
        echo "Deleting index: $index"
        curl -s -X DELETE "${OPENSEARCH_URL}/${index}" || { echo "Failed to delete index: $index"; exit 1; }
    done

    echo "Finished dropping existing indices."

    log "Started creating new indices."

    # All indexes are defined in separate JSON-files
    local uniprot_entries_index_file="${CURRENT_LOCATION}/../schemas_suffix_array/index_uniprot_entries.json"

    # Use the JSON file pointed to by the variable to create the new index
    if [[ -f "${uniprot_entries_index_file}" ]]; then
        curl -s -X PUT "${OPENSEARCH_URL}/uniprot_entries" -H 'Content-Type: application/json' -d @"${uniprot_entries_index_file}" || { echo "Failed to create uniprot_entries index"; exit 1; }
        echo "Successfully created uniprot_entries index."
    else
        echo "Index file ${uniprot_entries_index_file} does not exist."
        exit 1
    fi

    log "Finished creating new indices."
}

# This function reads in a list of UniProt-entries from stdin that are formatted as tsv and converts these to JSON
# objects (one object per line). These are compatible with the uniprot_entries index in OpenSearch.
convert_uniprot_entries_to_json() {
    while IFS=$'\t' read -r _ uniprot_accession_number version taxon_id type name protein; do
        # Create a JSON object for the current line using jq
        jq -c -n \
            --arg uniprot_accession_number "$uniprot_accession_number" \
            --argjson version "$version" \
            --argjson taxon_id "$taxon_id" \
            --arg type "$type" \
            --arg name "$name" \
            --arg protein "$protein" \
            '{
                uniprot_accession_number: $uniprot_accession_number,
                version: $version,
                taxon_id: $taxon_id,
                type: $type,
                name: $name,
                protein: $protein
            }'
    done
}

# Read the uniprot_entries file that was provided to the script, convert each line from the tsv to a valid JSON-object
# and upload them in bulk to the OpenSearch instance.
upload_uniprot_entries() {
    log "Started uploading UniProt entries."

    local counter=0
    local batch=""
    local start_time=$(date +%s)

    upload_batch() {
        local batch_content=$1
        local processed_counter=$2
        local start_time=$3

        # Upload the batch to the OpenSearch instance
        curl -s -X POST "${OPENSEARCH_URL}/_bulk" -H "Content-Type: application/json" --data-binary @<(echo "$batch_content") > /dev/null || { echo "Failed to upload batch"; exit 1; }

        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        local upload_rate=$((processed_counter / (elapsed_time > 0 ? elapsed_time : 1)))

        echo -ne "Uploaded $processed_counter proteins... [$upload_rate proteins/sec, elapsed time: ${elapsed_time}s]\r"
    }

    while IFS= read -r line; do
        # Add line to the current batch and increment counter
        batch+=$'{"index": { "_index": "uniprot_entries" }}\n'"${line}"$'\n'
        ((counter++))

        # If the batch size reaches the UPLOAD_BATCH_SIZE, process it
        if ((counter % UPLOAD_BATCH_SIZE == 0)); then
            upload_batch "$batch" "$counter" "$start_time"
            batch=""
        fi
    done < <(lz4cat "$UNIPROT_ENTRIES_FILE" | convert_uniprot_entries_to_json)

    # Upload any remaining records in the final batch
    if [[ -n "$batch" ]]; then
        upload_batch "$batch" "$counter" "$start_time"
    fi

    echo -e "\nUpload complete. Total proteins uploaded: $counter."

    log "Finished uploading UniProt entries."
}

checkdep "jq"
checkdep "lz4"
