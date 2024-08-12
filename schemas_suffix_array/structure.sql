SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0;
SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;
SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='TRADITIONAL';

-- Drop the old database. This database will be recreated further on during this script!
DROP DATABASE IF EXISTS `unipept`;

CREATE SCHEMA IF NOT EXISTS `unipept` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci ;
USE `unipept` ;


-- -----------------------------------------------------
-- Table `unipept`.`uniprot_entries`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS `unipept`.`uniprot_entries` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `uniprot_accession_number` CHAR(10) ASCII NOT NULL,
    `version` SMALLINT UNSIGNED NOT NULL,
    `taxon_id` MEDIUMINT UNSIGNED NOT NULL,
    `type` ENUM('swissprot', 'trembl') NOT NULL,
    `name` VARCHAR(150) NOT NULL,
    `protein` TEXT NOT NULL,
    PRIMARY KEY (`id`),
    INDEX `fk_uniprot_entries_taxons_idx` (`taxon_id` ASC),
    UNIQUE INDEX `idx_uniprot_entries_accession` (`uniprot_accession_number` ASC),
    CONSTRAINT `fk_uniprot_entries_taxons`
    FOREIGN KEY (`taxon_id`)
    REFERENCES `unipept`.`taxons` (`id`)
    ON DELETE NO ACTION
    ON UPDATE NO ACTION)
    ENGINE = InnoDB
    DEFAULT CHARACTER SET = ascii
    COLLATE = ascii_general_ci;
SET SQL_MODE=@OLD_SQL_MODE;
SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;
SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS;
