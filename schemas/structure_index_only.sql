SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0;
SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;
SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='TRADITIONAL';

-- -----------------------------------------------------
-- Table `unipept`.`taxons`
-- -----------------------------------------------------
-- ALTER TABLE taxons ADD INDEX fk_taxon_taxon (parent_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`uniprot_entries`
-- -----------------------------------------------------
ALTER TABLE uniprot_entries ADD INDEX fk_uniprot_entries_taxons (taxon_id ASC);
ALTER TABLE uniprot_entries ADD UNIQUE INDEX idx_uniprot_entries_accession (uniprot_accession_number ASC)


-- -----------------------------------------------------
-- Table `unipept`.`ec_numbers`
-- -----------------------------------------------------
ALTER TABLE ec_numbers ADD UNIQUE INDEX idx_ec_code (code ASC);


-- -----------------------------------------------------
-- Table `unipept`.`go_terms`
-- -----------------------------------------------------
ALTER TABLE go_terms ADD UNIQUE INDEX idx_go_code (code ASC);


-- -----------------------------------------------------
-- Table `unipept`.`interpro`
-- -----------------------------------------------------
ALTER TABLE interpro_entries ADD UNIQUE INDEX idx_interpro_code (code ASC);


-- -----------------------------------------------------
-- Table `unipept`.`sequences`
-- -----------------------------------------------------
ALTER TABLE sequences ADD UNIQUE INDEX idx_sequences (sequence ASC);
ALTER TABLE sequences ADD INDEX fk_sequences_taxons (lca ASC), ADD INDEX fk_sequences_taxons_2 (lca_il ASC);


-- -----------------------------------------------------
-- Table `unipept`.`peptides`
-- -----------------------------------------------------
ALTER TABLE peptides ADD INDEX fk_peptides_sequences (sequence_id ASC), ADD INDEX fk_peptides_uniprot_entries (uniprot_entry_id ASC), ADD INDEX fk_peptides_original_sequences (original_sequence_id ASC);


-- -----------------------------------------------------
-- Table `unipept`.`go_cross_references`
-- -----------------------------------------------------
ALTER TABLE go_cross_references ADD INDEX fk_go_reference_uniprot_entries (uniprot_entry_id ASC);
-- ALTER TABLE go_cross_references ADD INDEX fk_go_cross_reference_go_terms_idx (go_term_code ASC);


-- -----------------------------------------------------
-- Table `unipept`.`ec_cross_references`
-- -----------------------------------------------------
ALTER TABLE ec_cross_references ADD INDEX fk_ec_reference_uniprot_entries (uniprot_entry_id ASC);
-- ALTER TABLE ec_cross_references ADD INDEX fk_ec_terms_reference_go_terms_idx (ec_number_code ASC);


-- -----------------------------------------------------
-- Table `unipept`.`interpro_cross_references`
-- -----------------------------------------------------
ALTER TABLE interpro_cross_references ADD INDEX fk_interpro_reference_uniprot_entries (uniprot_entry_id ASC);


SET SQL_MODE=@OLD_SQL_MODE;
SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;
SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS;
