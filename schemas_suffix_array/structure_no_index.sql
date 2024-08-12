SET session_replication_role = 'replica';

CREATE SCHEMA IF NOT EXISTS "unipept";

DO $$ BEGIN
CREATE TYPE DB_TYPE AS ENUM ('swissprot', 'trembl');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- -----------------------------------------------------
-- Table "unipept"."uniprot_entries"
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS "unipept"."uniprot_entries" (
    "id" BIGINT NOT NULL PRIMARY KEY ,
    "uniprot_accession_number" CHAR(10) NOT NULL ,
    "version" INT NOT NULL ,
    "taxon_id" INT NOT NULL ,
    "type" DB_TYPE NOT NULL ,
    "name" VARCHAR(150) NOT NULL ,
    "protein" TEXT NOT NULL,
    `fa` TEXT NOT NULL
);

SET session_replication_role = 'origin';
