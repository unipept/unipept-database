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


SET SQL_MODE=@OLD_SQL_MODE;
SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;
SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS;
