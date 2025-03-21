SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0;
SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;
SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='TRADITIONAL';

-- Drop the old database. This database will be recreated further on during this script!
DROP DATABASE IF EXISTS `unipept`;

CREATE SCHEMA IF NOT EXISTS `unipept` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci ;
USE `unipept` ;

-- -----------------------------------------------------
-- Table `unipept`.`taxons`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`taxons` (
  `id` MEDIUMINT UNSIGNED NOT NULL ,
  `name` VARCHAR(120) NOT NULL ,
  `rank` ENUM('no rank', 'domain', 'realm', 'kingdom', 'subkingdom', 'superphylum', 'phylum', 'subphylum', 'superclass', 'class', 'subclass', 'superorder', 'order', 'suborder', 'infraorder', 'superfamily', 'family', 'subfamily', 'tribe', 'subtribe', 'genus', 'subgenus', 'species group', 'species subgroup', 'species', 'subspecies', 'strain', 'varietas', 'forma' ) NULL DEFAULT NULL ,
  `parent_id` MEDIUMINT UNSIGNED NULL DEFAULT NULL ,
  `valid_taxon` BIT NOT NULL DEFAULT 1 ,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = utf8
COLLATE = utf8_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`uniprot_entries`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`uniprot_entries` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `uniprot_accession_number` CHAR(10) ASCII NOT NULL ,
  `version` SMALLINT UNSIGNED NOT NULL ,
  `taxon_id` MEDIUMINT UNSIGNED NOT NULL ,
  `type` ENUM('swissprot', 'trembl') NOT NULL ,
  `name`VARCHAR(150) NOT NULL ,
  `protein` TEXT NOT NULL ,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
COLLATE = ascii_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`ec_numbers`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS `unipept`.`ec_numbers` (
  `id` SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `code` VARCHAR(15) NOT NULL,
  `name` VARCHAR(155) NOT NULL,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = utf8
COLLATE = utf8_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`go_terms`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS `unipept`.`go_terms` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `code` VARCHAR(15) NOT NULL,
  `namespace` ENUM('biological process', 'molecular function', 'cellular component') NOT NULL,
  `name` VARCHAR(200) NOT NULL,
  PRIMARY KEY (`id`))
ENGINE = InnoDB;


-- -----------------------------------------------------
-- Table `unipept`.`interpro`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS `unipept`.`interpro_entries` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
    `code` VARCHAR(9) NOT NULL,
    `category` VARCHAR(32) NOT NULL,
    `name` VARCHAR(160) NOT NULL,
    PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
COLLATE = ascii_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`lineages`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`lineages` (
  `taxon_id` MEDIUMINT UNSIGNED NOT NULL ,
  `domain` MEDIUMINT NULL DEFAULT NULL ,
  `realm` MEDIUMINT NULL DEFAULT NULL ,
  `kingdom` MEDIUMINT NULL DEFAULT NULL ,
  `subkingdom` MEDIUMINT NULL DEFAULT NULL ,
  `superphylum` MEDIUMINT NULL DEFAULT NULL ,
  `phylum` MEDIUMINT NULL DEFAULT NULL ,
  `subphylum` MEDIUMINT NULL DEFAULT NULL ,
  `superclass` MEDIUMINT NULL DEFAULT NULL ,
  `class` MEDIUMINT NULL DEFAULT NULL ,
  `subclass` MEDIUMINT NULL DEFAULT NULL ,
  `superorder` MEDIUMINT NULL DEFAULT NULL ,
  `order` MEDIUMINT NULL DEFAULT NULL ,
  `suborder` MEDIUMINT NULL DEFAULT NULL ,
  `infraorder` MEDIUMINT NULL DEFAULT NULL ,
  `superfamily` MEDIUMINT NULL DEFAULT NULL ,
  `family` MEDIUMINT NULL DEFAULT NULL ,
  `subfamily` MEDIUMINT NULL DEFAULT NULL ,
  `tribe` MEDIUMINT NULL DEFAULT NULL ,
  `subtribe` MEDIUMINT NULL DEFAULT NULL ,
  `genus` MEDIUMINT NULL DEFAULT NULL ,
  `subgenus` MEDIUMINT NULL DEFAULT NULL ,
  `species_group` MEDIUMINT NULL DEFAULT NULL ,
  `species_subgroup` MEDIUMINT NULL DEFAULT NULL ,
  `species` MEDIUMINT NULL DEFAULT NULL ,
  `subspecies` MEDIUMINT NULL DEFAULT NULL ,
  `strain` MEDIUMINT NULL DEFAULT NULL ,
  `varietas` MEDIUMINT NULL DEFAULT NULL ,
  `forma` MEDIUMINT NULL DEFAULT NULL ,
  PRIMARY KEY (`taxon_id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
COLLATE = ascii_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`sequences`
-- BLOCKSIZE 16 IS DEFAULT BLOCKSIZE
-- Only BLOBS will get compressed
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`sequences` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `sequence` VARCHAR(50) NOT NULL ,
  `lca` MEDIUMINT UNSIGNED NULL ,
  `lca_il` MEDIUMINT UNSIGNED NULL ,
  `fa`  MEDIUMBLOB NULL ,
  `fa_il`  MEDIUMBLOB NULL ,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=16
COLLATE = ascii_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`peptides`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`peptides` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `sequence_id` INT UNSIGNED NOT NULL ,
  `original_sequence_id` INT UNSIGNED NOT NULL ,
  `uniprot_entry_id` INT UNSIGNED NOT NULL ,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
COLLATE = ascii_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`datasets`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`datasets` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `environment` VARCHAR(160) NULL ,
  `reference` VARCHAR(500) NULL ,
  `url` VARCHAR(200) NULL ,
  `project_website` VARCHAR(200) NULL ,
  PRIMARY KEY (`id`) )
ENGINE = InnoDB
DEFAULT CHARACTER SET = utf8
COLLATE = utf8_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`dataset_items`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`dataset_items` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `dataset_id` INT UNSIGNED NULL ,
  `name` VARCHAR(160) NULL ,
  `data` MEDIUMTEXT CHARACTER SET 'ascii' COLLATE 'ascii_general_ci' NOT NULL ,
  `order` INT NULL ,
  PRIMARY KEY (`id`) ,
  INDEX `fk_dataset_items_datasets` (`dataset_id` ASC) ,
  CONSTRAINT `fk_dataset_items_datasets`
    FOREIGN KEY (`dataset_id` )
    REFERENCES `unipept`.`datasets` (`id` )
    ON DELETE NO ACTION
    ON UPDATE NO ACTION)
ENGINE = InnoDB
DEFAULT CHARACTER SET = utf8
COLLATE = utf8_general_ci;

-- -----------------------------------------------------
-- Table `unipept`.`go_cross_references`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`go_cross_references` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `uniprot_entry_id` INT UNSIGNED NOT NULL ,
  `go_term_code` VARCHAR(15) NOT NULL ,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
COLLATE = ascii_general_ci;


-- -----------------------------------------------------
-- Table `unipept`.`ec_cross_references`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`ec_cross_references` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `uniprot_entry_id` INT UNSIGNED NOT NULL ,
  `ec_number_code` VARCHAR(15) NOT NULL ,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
COLLATE = ascii_general_ci;

-- -----------------------------------------------------
-- Table `unipept`.`interpro_cross_references`
-- -----------------------------------------------------
CREATE  TABLE IF NOT EXISTS `unipept`.`interpro_cross_references` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT ,
  `uniprot_entry_id` INT UNSIGNED NOT NULL ,
  `interpro_entry_code` VARCHAR(9) NOT NULL ,
  PRIMARY KEY (`id`))
ENGINE = InnoDB
DEFAULT CHARACTER SET = ascii
COLLATE = ascii_general_ci;


SET SQL_MODE=@OLD_SQL_MODE;
SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;
SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS;
