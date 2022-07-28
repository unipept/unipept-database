-- This file provides some code to initialize virtual tables in our Unipept static database that aid to drastically
-- improve query performance in specific situations (such as looking for taxa that contain a specific text in their
-- name).

-- First we have to create a new virtual table. Afterwards we can populate this table with content from the pre-existing
-- taxon table.
CREATE VIRTUAL TABLE `virtual_taxons` USING fts5 (
    id,
    name
);

-- Now, populate this table using the data that's already present in the taxons table.
INSERT INTO `virtual_taxons` SELECT id, name FROM `taxons`;
