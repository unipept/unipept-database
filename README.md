# Unipept's database creation

The Unipept [metaproteomics] and [metagenomics] pipelines operate on data found in the [Uniprot] database. This collection of scripts is provided to download and process that database (or others) into a useable format.

To configure these scripts to run on your computer, run the interactive `configure` script.

Afterwards, run `make database` to build the database tables for the metaproteomics webserver or `make index` to build the index files for the metagenomics pipeline. Running just `make` will create both.

To safe some space, run `make clean_intermediates` afterwards to remove intermediate files.

The `make-on-hpc.sh` script contains information on how to run this on our own high performance computing infrastructure.

[metaproteomics]: https://github.com/unipept/unipept
[metagenomics]: https://github.com/unipept/umgap
