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
