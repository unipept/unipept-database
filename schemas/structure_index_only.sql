SET session_replication_role = 'replica';


-- -----------------------------------------------------
-- Table `unipept`.`uniprot_entries`
-- -----------------------------------------------------
CREATE INDEX fk_uniprot_entries_taxons ON uniprot_entries (taxon_id ASC);
CREATE UNIQUE INDEX idx_uniprot_entries_accession ON uniprot_entries (uniprot_accession_number ASC);

-- -----------------------------------------------------
-- Table `unipept`.`ec_numbers`
-- -----------------------------------------------------
CREATE UNIQUE INDEX idx_ec_code ON ec_numbers (code ASC);

-- -----------------------------------------------------
-- Table `unipept`.`go_terms`
-- -----------------------------------------------------
CREATE UNIQUE INDEX idx_go_code ON go_terms (code ASC);

-- -----------------------------------------------------
-- Table `unipept`.`interpro`
-- -----------------------------------------------------
CREATE UNIQUE INDEX idx_interpro_code ON interpro_entries (code ASC);


-- -----------------------------------------------------
-- Table `unipept`.`sequences`
-- -----------------------------------------------------
CREATE UNIQUE INDEX idx_sequences ON sequences (sequence ASC);
CREATE INDEX fk_sequences_taxons ON sequences (lca ASC);
CREATE INDEX fk_sequences_taxons_2 ON sequences (lca_il ASC);


-- -----------------------------------------------------
-- Table `unipept`.`peptides`
-- -----------------------------------------------------
CREATE INDEX fk_peptides_sequences ON peptides (sequence_id ASC);
CREATE INDEX fk_peptides_uniprot_entries ON peptides (uniprot_entry_id ASC);
CREATE INDEX fk_peptides_original_sequences ON peptides (original_sequence_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`seq_fa_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_seq_fa_cross_reference_seq_idx ON seq_fa_cross_references (seq_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`seq_fa_il_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_seq_fa_il_cross_reference_seq_idx ON seq_fa_il_cross_references (seq_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`seq_taxa_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_seq_taxa_cross_reference_seq_idx ON seq_taxa_cross_references (seq_id ASC);
CREATE INDEX fk_seq_taxa_cross_reference_taxa_idx ON seq_taxa_cross_references (taxon_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`seq_taxa_il_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_seq_taxa_il_cross_reference_seq_idx ON seq_taxa_il_cross_references (seq_id ASC);
CREATE INDEX fk_seq_taxa_il_cross_reference_taxa_idx ON seq_taxa_il_cross_references (taxon_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`go_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_go_reference_uniprot_entries ON go_cross_references (uniprot_entry_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`ec_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_ec_reference_uniprot_entries ON ec_cross_references (uniprot_entry_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`interpro_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_interpro_reference_uniprot_entries ON interpro_cross_references (uniprot_entry_id ASC);

-- -----------------------------------------------------
-- Table `unipept`.`taxon_cross_references`
-- -----------------------------------------------------
CREATE INDEX fk_taxon_reference_sequences ON taxon_cross_references (sequence_id ASC);


SET session_replication_role = 'origin';
