# unipept-database

The Unipept [metaproteomics] and [metagenomics] pipelines operate on data found in the [UniProtKB](https://www.uniprot.org/) database. 
This collection of scripts is provided to download and process that database (or others) into range of `tsv`-files that can directly be used by the Unipept pipeline.

## Most important scripts

### scripts/generate_sa_tables.sh

This script is responsible for parsing the UniProtKB database and generating several `.tsv.lz4` files that are essential for the Unipept pipeline that generates a suffix array (see [unipept-index](https://github.com/unipept/unipept-index)). 
These files contain structured information extracted from the database in a compressed format for efficient storage and processing. 
Below is an overview of the generated files and what they represent:

- **taxons.tsv.lz4**: This file contains data on NCBI taxonomic identifiers and their corresponding scientific names, providing information about the classification of organisms.
- **lineages.tsv.lz4**: A detailed representation of taxonomic lineages (according to the NCBI taxonomy), mapping organisms to their hierarchical classification (e.g., kingdom, phylum, class, etc.).
- **go_terms.tsv.lz4**: This file contains Gene Ontology (GO) terms mapped to their full name and namespace.
- **ec_numbers.tsv.lz4**: This file contains Enzyme Commission (EC) numbers, mapped to their full name and namespace.
- **interpro_entries.tsv.lz4**: This file lists InterPro entries mapped to their full name and namespace.
- **uniprot_entries.tsv.lz4**: This file contains protein sequences, together with their UniProtKB accession number, as well as the associated NCBI taxon IDs, and functional annotations (GO, EC and InterPro).
- **.version**: Contains a reference to the version number of the UniProtKB database that was used as input to this script.

See [our wiki](https://github.com/unipept/unipept-database/wiki/Building-tables-for-the-suffix-array) for more information on how to run this script.

### scripts/generate_umgap_tables.sh

This script is responsible for parsing datasets to generate files required by the Unipept metagenomics pipeline, which constructs a metagenomics index. 
The script supports two distinct modes—`kmer` and `tryptic`—to create two different types of metagenomics indices optimized for different analytical purposes.

Below is an overview of the two supported modes and the files generated:

**Kmer mode**:  
This mode generates a metagenomics index based on k-mers (short nucleotide or peptide sequences of fixed length). 
This approach is highly efficient for large-scale metagenomics data and allows for rapid matching and analysis of unassembled reads within metagenomic datasets.

**Tryptic mode**:  
This mode constructs the index based on tryptic peptide sequences. 
Tryptic peptides result from in silico digestion of protein sequences using trypsin digestion rules. 
This method is well-suited for metaproteomics workflows where peptide-level functional and taxonomic analyses are required.

Both modes output data in a binary `.index` file to ensure efficient storage and processing that can directly be used by the UMGAP pipeline.

See [our wiki](https://github.com/unipept/unipept-database/wiki/Building-the-UMGAP-indexes) for more information on how to run this script.

[metaproteomics]: https://github.com/unipept/unipept
[metagenomics]: https://github.com/unipept/umgap
