SET session_replication_role = "replica";

-- Drop the old database. This database will be recreated further on during this script!
DROP SCHEMA IF EXISTS "unipept" CASCADE;

CREATE SCHEMA IF NOT EXISTS "unipept";


-- -----------------------------------------------------
-- Enums
-- -----------------------------------------------------
DO
$$
    BEGIN
        CREATE TYPE RANK_TYPE AS ENUM ('no rank', 'superkingdom', 'kingdom', 'subkingdom', 'superphylum', 'phylum', 'subphylum', 'superclass', 'class', 'subclass', 'superorder', 'order', 'suborder', 'infraorder', 'superfamily', 'family', 'subfamily', 'tribe', 'subtribe', 'genus', 'subgenus', 'species group', 'species subgroup', 'species', 'subspecies', 'strain', 'varietas', 'forma');
    EXCEPTION
        WHEN duplicate_object THEN null;
    END
$$;

DO
$$
    BEGIN
        CREATE TYPE DB_TYPE AS ENUM ('swissprot', 'trembl');
    EXCEPTION
        WHEN duplicate_object THEN null;
    END
$$;

DO
$$
    BEGIN
        CREATE TYPE GO_NAMESPACE AS ENUM ('biological process', 'molecular function', 'cellular component');
    EXCEPTION
        WHEN duplicate_object THEN null;
    END
$$;


-- -----------------------------------------------------
-- Table `unipept`.`taxons`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."taxons"
(
    "id"          INT          NOT NULL PRIMARY KEY,
    "name"        VARCHAR(120) NOT NULL,
    "rank"        RANK_TYPE    NULL     DEFAULT NULL,
    "parent_id"   INT          NULL     DEFAULT NULL,
    "valid_taxon" SMALLINT     NOT NULL DEFAULT 1 NOT NULL DEFAULT 1
);


-- -----------------------------------------------------
-- Table `unipept`.`uniprot_entries`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."uniprot_entries"
(
    "id"                       INT          NOT NULL PRIMARY KEY,
    "uniprot_accession_number" CHAR(10)     NOT NULL,
    "version"                  INT          NOT NULL,
    "taxon_id"                 INT          NOT NULL,
    "type"                     DB_TYPE      NOT NULL,
    "name"                     VARCHAR(150) NOT NULL,
    "protein"                  TEXT         NOT NULL
);


-- -----------------------------------------------------
-- Table `unipept`.`ec_numbers`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."ec_numbers"
(
    "id"   INT          NOT NULL PRIMARY KEY,
    "code" VARCHAR(15)  NOT NULL,
    "name" VARCHAR(155) NOT NULL
);


-- -----------------------------------------------------
-- Table `unipept`.`go_terms`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."go_terms"
(
    "id"        INT          NOT NULL PRIMARY KEY,
    "code"      VARCHAR(15)  NOT NULL,
    "namespace" GO_NAMESPACE NOT NULL,
    "name"      VARCHAR(200) NOT NULL
);


-- -----------------------------------------------------
-- Table `unipept`.`interpro_entries`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."interpro_entries"
(
    "id"       INT          NOT NULL PRIMARY KEY,
    "code"     VARCHAR(9)   NOT NULL,
    "category" VARCHAR(32)  NOT NULL,
    "name"     VARCHAR(160) NOT NULL
);


-- -----------------------------------------------------
-- Table `unipept`.`lineages`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."lineages"
(
    "taxon_id"         INT NOT NULL PRIMARY KEY,
    "superkingdom"     INT NULL DEFAULT NULL,
    "kingdom"          INT NULL DEFAULT NULL,
    "subkingdom"       INT NULL DEFAULT NULL,
    "superphylum"      INT NULL DEFAULT NULL,
    "phylum"           INT NULL DEFAULT NULL,
    "subphylum"        INT NULL DEFAULT NULL,
    "superclass"       INT NULL DEFAULT NULL,
    "class"            INT NULL DEFAULT NULL,
    "subclass"         INT NULL DEFAULT NULL,
    "superorder"       INT NULL DEFAULT NULL,
    "order"            INT NULL DEFAULT NULL,
    "suborder"         INT NULL DEFAULT NULL,
    "infraorder"       INT NULL DEFAULT NULL,
    "superfamily"      INT NULL DEFAULT NULL,
    "family"           INT NULL DEFAULT NULL,
    "subfamily"        INT NULL DEFAULT NULL,
    "tribe"            INT NULL DEFAULT NULL,
    "subtribe"         INT NULL DEFAULT NULL,
    "genus"            INT NULL DEFAULT NULL,
    "subgenus"         INT NULL DEFAULT NULL,
    "species_group"    INT NULL DEFAULT NULL,
    "species_subgroup" INT NULL DEFAULT NULL,
    "species"          INT NULL DEFAULT NULL,
    "subspecies"       INT NULL DEFAULT NULL,
    "strain"           INT NULL DEFAULT NULL,
    "varietas"         INT NULL DEFAULT NULL,
    "forma"            INT NULL DEFAULT NULL
);


-- -----------------------------------------------------
-- Table "unipept"."sequences"
CREATE TABLE IF NOT EXISTS "unipept"."sequences"
(
    "id"       BIGINT      NOT NULL PRIMARY KEY,
    "sequence" VARCHAR(50) NOT NULL,
    "lca"      INT         NULL,
    "lca_il"   INT         NULL,
    "fa"       BYTEA       NULL,
    "fa_il"    BYTEA       NULL
);


-- -----------------------------------------------------
-- Table "unipept"."peptides"
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."peptides"
(
    "id"                   BIGINT NOT NULL PRIMARY KEY,
    "sequence_id"          BIGINT NOT NULL,
    "original_sequence_id" BIGINT NOT NULL,
    "uniprot_entry_id"     BIGINT NOT NULL
);


-- -----------------------------------------------------
-- Table "unipept"."datasets"
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."datasets"
(
    "id"              INT          NOT NULL PRIMARY KEY,
    "environment"     VARCHAR(160) NULL,
    "reference"       VARCHAR(500) NULL,
    "url"             VARCHAR(200) NULL,
    "project_website" VARCHAR(200) NULL
);


-- -----------------------------------------------------
-- Table "unipept"."dataset_items"
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."dataset_items"
(
    "id"         INT          NOT NULL PRIMARY KEY,
    "dataset_id" BIGINT       NULL,
    "name"       VARCHAR(160) NULL,
    "data"       TEXT         NOT NULL,
    "order"      INT          NULL,
    CONSTRAINT "fk_dataset_items_datasets"
        FOREIGN KEY ("dataset_id")
            REFERENCES "unipept"."datasets" ("id")
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
);


-- -----------------------------------------------------
-- Table `unipept`.`go_cross_references`
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."go_cross_references"
(
    "id"               BIGINT      NOT NULL PRIMARY KEY,
    "uniprot_entry_id" BIGINT      NOT NULL,
    "go_term_code"     VARCHAR(15) NOT NULL
);


-- -----------------------------------------------------
-- Table "unipept"."ec_cross_references"
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."ec_cross_references"
(
    "id"               BIGINT      NOT NULL PRIMARY KEY,
    "uniprot_entry_id" BIGINT      NOT NULL,
    "ec_number_code"   VARCHAR(15) NOT NULL
);


-- -----------------------------------------------------
-- Table "unipept"."taxon_cross_references"
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."taxon_cross_references"
(
    "id"          BIGINT     NOT NULL PRIMARY KEY,
    "sequence_id" BIGINT     NOT NULL,
    "taxon_id"    VARCHAR(9) NOT NULL
);


SET session_replication_role = "origin";
