ALTER TABLE unipept.taxons
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.uniprot_entries
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.ec_numbers
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.go_terms
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.interpro_entries
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.lineages
    ADD PRIMARY KEY (taxon_id);
ALTER TABLE unipept.sequences
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.peptides
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.datasets
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.dataset_items
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.dataset_items
    ADD CONSTRAINT fk_dataset_items_datasets
        FOREIGN KEY (dataset_id)
            REFERENCES unipept.datasets (id)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION;
ALTER TABLE unipept.go_cross_references
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.ec_cross_references
    ADD PRIMARY KEY (id);
ALTER TABLE unipept.interpro_cross_references
    ADD PRIMARY KEY (id);

