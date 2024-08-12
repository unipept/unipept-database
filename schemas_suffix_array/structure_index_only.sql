SET session_replication_role = 'replica';

-- -----------------------------------------------------
-- Table `unipept`.`uniprot_entries`
-- -----------------------------------------------------
CREATE INDEX fk_uniprot_entries_taxons ON uniprot_entries (taxon_id ASC);
CREATE UNIQUE INDEX idx_uniprot_entries_accession ON uniprot_entries (uniprot_accession_number ASC);

SET session_replication_role = 'origin';
