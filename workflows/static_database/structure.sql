CREATE TABLE `go_terms` (
  `id` INT NOT NULL,
  `code` TEXT NOT NULL,
  `namespace` TEXT NOT NULL,
  `name` TEXT NOT NULL,
  PRIMARY KEY (`id`)
);

CREATE UNIQUE INDEX idx_go_code ON go_terms(code);

CREATE TABLE `ec_numbers` (
  `id` INT NOT NULL,
  `code` TEXT NOT NULL,
  `name` TEXT NOT NULL,
  PRIMARY KEY (`id`)
);

CREATE UNIQUE INDEX idx_ec_code ON ec_numbers(code);

CREATE TABLE `interpro_entries` (
  `id` INT NOT NULL ,
  `code` TEXT NOT NULL,
  `category` TEXT NOT NULL,
  `name` TEXT NOT NULL,
  PRIMARY KEY (`id`)
);

CREATE UNIQUE INDEX idx_ipr_code ON interpro_entries(code);

CREATE TABLE IF NOT EXISTS `taxons` (
  `id` INT UNSIGNED NOT NULL ,
  `name` TEXT NOT NULL ,
  `rank` TEXT NULL DEFAULT NULL ,
  `parent_id` INT NULL DEFAULT NULL ,
  `valid_taxon` INT NOT NULL DEFAULT 1 ,
  PRIMARY KEY (`id`)
);

CREATE TABLE `lineages` (
  `taxon_id` INT NOT NULL ,
  `domain` INT NULL DEFAULT NULL ,
  `realm` INT NULL DEFAULT NULL ,
  `kingdom` INT NULL DEFAULT NULL ,
  `subkingdom` INT NULL DEFAULT NULL ,
  `superphylum` INT NULL DEFAULT NULL ,
  `phylum` INT NULL DEFAULT NULL ,
  `subphylum` INT NULL DEFAULT NULL ,
  `superclass` INT NULL DEFAULT NULL ,
  `class` INT NULL DEFAULT NULL ,
  `subclass` INT NULL DEFAULT NULL ,
  `superorder` INT NULL DEFAULT NULL ,
  `order` INT NULL DEFAULT NULL ,
  `suborder` INT NULL DEFAULT NULL ,
  `infraorder` INT NULL DEFAULT NULL ,
  `superfamily` INT NULL DEFAULT NULL ,
  `family` INT NULL DEFAULT NULL ,
  `subfamily` INT NULL DEFAULT NULL ,
  `tribe` INT NULL DEFAULT NULL ,
  `subtribe` INT NULL DEFAULT NULL ,
  `genus` INT NULL DEFAULT NULL ,
  `subgenus` INT NULL DEFAULT NULL ,
  `species_group` INT NULL DEFAULT NULL ,
  `species_subgroup` INT NULL DEFAULT NULL ,
  `species` INT NULL DEFAULT NULL ,
  `subspecies` INT NULL DEFAULT NULL ,
  `strain` INT NULL DEFAULT NULL ,
  `varietas` INT NULL DEFAULT NULL ,
  `forma` INT NULL DEFAULT NULL ,
  PRIMARY KEY (`taxon_id`)
);
