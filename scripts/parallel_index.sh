#!/bin/bash

# Define MySQL connection parameters
DB_USER="unipept"
DB_PASSWORD="unipept"
DB_HOST="localhost"
DB_NAME="unipept"

# Function to add an index in the background
add_index() {
    local table_name=$1
    local column_name=$2

    # Execute the "add index" statement
    mysql -u "$DB_USER" -p"$DB_PASSWORD" -h "$DB_HOST" -e "ALTER TABLE $DB_NAME.$table_name ADD INDEX idx_$column_name ($column_name);" &
}

# List of tables and columns for which you want to add indexes
table_columns=(
    "uniprot_entries:taxon_id"
    "uniprot_entries:uniprot_accession_number"
    "ec_numbers:code"
    "go_terms:code"
    "sequences:sequence"
    "sequences:lca"
    "sequences:lca_il"
    "peptides:sequence_id"
    "peptides:uniprot_entry_id"
    "peptides:original_sequence_id"
    "go_cross_references:uniprot_entry_id"
    "ec_cross_references:uniprot_entry_id"
    "interpro_cross_references:uniprot_entry_id"
)

# Loop through the list and add indexes in parallel
for entry in "${table_columns[@]}"; do
    table=${entry%%:*}
    column=${entry#*:}
    add_index "$table" "$column"
done

# Wait for all background jobs to finish
wait

echo "All index statements have been executed."