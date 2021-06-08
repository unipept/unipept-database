-- First create a new table `unipept3` that will temporary hold all the required information from the previous UniProt
-- version (that is still in the `unipept` database).

CREATE SCHEMA `unipept3` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;

-- Now, move the tables from `unipept` to `unipept3` before continueing. `unipept3` will thus temporary hold all the
-- backup data for the database.
RENAME TABLE unipept.ec_cross_references TO unipept3.ec_cross_references;
RENAME TABLE unipept.ec_numbers TO unipept3.ec_numbers;
RENAME TABLE unipept.interpro_cross_references TO unipept3.interpro_cross_references;
RENAME TABLE unipept.interpro_entries TO unipept3.interpro_entries;
RENAME TABLE unipept.embl_cross_references TO unipept3.embl_cross_references;
RENAME TABLE unipept.go_cross_references TO unipept3.go_cross_references;
RENAME TABLE unipept.go_terms TO unipept3.go_terms;
RENAME TABLE unipept.lineages TO unipept3.lineages;
RENAME TABLE unipept.peptides TO unipept3.peptides;
RENAME TABLE unipept.refseq_cross_references TO unipept3.refseq_cross_references;
RENAME TABLE unipept.sequences TO unipept3.sequences;
RENAME TABLE unipept.taxons TO unipept3.taxons;
RENAME TABLE unipept.uniprot_entries TO unipept3.uniprot_entries;
RENAME TABLE unipept.proteomes TO unipept3.proteomes;
RENAME TABLE unipept.proteome_cross_references TO unipept3.proteome_cross_references;
RENAME TABLE unipept.proteome_caches TO unipept3.proteome_caches;

-- Move the most recent UniProt release data to the current production database (`unipept`)
RENAME TABLE unipept2.ec_cross_references TO unipept.ec_cross_references;
RENAME TABLE unipept2.ec_numbers TO unipept.ec_numbers;
RENAME TABLE unipept2.interpro_cross_references TO unipept.interpro_cross_references;
RENAME TABLE unipept2.interpro_entries TO unipept.interpro_entries;
RENAME TABLE unipept2.embl_cross_references TO unipept.embl_cross_references;
RENAME TABLE unipept2.go_cross_references TO unipept.go_cross_references;
RENAME TABLE unipept2.go_terms TO unipept.go_terms;
RENAME TABLE unipept2.lineages TO unipept.lineages;
RENAME TABLE unipept2.peptides TO unipept.peptides;
RENAME TABLE unipept2.refseq_cross_references TO unipept.refseq_cross_references;
RENAME TABLE unipept2.sequences TO unipept.sequences;
RENAME TABLE unipept2.taxons TO unipept.taxons;
RENAME TABLE unipept2.uniprot_entries TO unipept.uniprot_entries;
RENAME TABLE unipept2.proteomes TO unipept.proteomes;
RENAME TABLE unipept2.proteome_cross_references TO unipept.proteome_cross_references;
RENAME TABLE unipept2.proteome_caches TO unipept.proteome_caches;

-- Finally, move the temporary table (`unipept3`) back to `unipept2` (`unipept` always holds a copy of the previous
-- UniProt release. This way we can easily rollback to a previous version of the database in case something is wrong.)
RENAME TABLE unipept3.ec_cross_references TO unipept2.ec_cross_references;
RENAME TABLE unipept3.ec_numbers TO unipept2.ec_numbers;
RENAME TABLE unipept3.interpro_cross_references TO unipept2.interpro_cross_references;
RENAME TABLE unipept3.interpro_entries TO unipept2.interpro_entries;
RENAME TABLE unipept3.embl_cross_references TO unipept2.embl_cross_references;
RENAME TABLE unipept3.go_cross_references TO unipept2.go_cross_references;
RENAME TABLE unipept3.go_terms TO unipept2.go_terms;
RENAME TABLE unipept3.lineages TO unipept2.lineages;
RENAME TABLE unipept3.peptides TO unipept2.peptides;
RENAME TABLE unipept3.refseq_cross_references TO unipept2.refseq_cross_references;
RENAME TABLE unipept3.sequences TO unipept2.sequences;
RENAME TABLE unipept3.taxons TO unipept2.taxons;
RENAME TABLE unipept3.uniprot_entries TO unipept2.uniprot_entries;
RENAME TABLE unipept3.proteomes TO unipept2.proteomes;
RENAME TABLE unipept3.proteome_cross_references TO unipept2.proteome_cross_references;
RENAME TABLE unipept3.proteome_caches TO unipept2.proteome_caches;

-- Remove the temporary database `unipept3`. This database is empty now, and is no longer required.
DROP DATABASE IF EXISTS `unipept3`;
