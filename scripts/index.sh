#!/bin/bash
# adds indexes to the unipept database
logfile=$(date +%F_%T).txt
sequencesTable="sequences"
# sequencesTable="sequences_compressed"

echo "Script started" > $logfile

function print {
    echo $(date +'%F %T') $1 | tee -a $logfile
}

function print {
    echo $(date -u) $1
}

function doCmd {
    echo -n "-> "
    print "$1"
    echo $1 | mariadb -u unipept -punipept unipept 2>&1 | sed "s/^/   /" | grep -v "Using a password on the command line interface can be insecure" | tee -a $logfile
}

print "adding index to uniprot_entries"
doCmd "ALTER TABLE uniprot_entries ADD INDEX fk_uniprot_entries_taxons (taxon_id ASC);"
doCmd "ALTER TABLE uniprot_entries ADD UNIQUE INDEX idx_uniprot_entries_accession (uniprot_accession_number ASC);"

print "adding index to ec_numbers"
doCmd "ALTER TABLE ec_numbers ADD UNIQUE INDEX idx_ec_numbers (code ASC);"

print "adding index to go_terms"
doCmd "ALTER TABLE go_terms ADD UNIQUE INDEX idx_go_code (code ASC);"

print "adding index to interpro_entries"
doCmd "ALTER TABLE interpro ADD UNIQUE INDEX idx_interpro_entries (code ASC);"

print "adding index to go_cross_references"
doCmd "ALTER TABLE go_cross_references ADD INDEX fk_go_reference_uniprot_entries (uniprot_entry_id ASC);"

print "adding index to ec_cross_references"
doCmd "ALTER TABLE ec_cross_references ADD INDEX fk_ec_reference_uniprot_entries (uniprot_entry_id ASC);"

print "adding index to interpro_cross_references"
doCmd "ALTER TABLE interpro_cross_references ADD INDEX fk_interpro_reference_uniprot_entries (uniprot_entry_id ASC);"

print "Done"
