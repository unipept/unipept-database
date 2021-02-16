# Unipept's database creation

The Unipept [metaproteomics] and [metagenomics] pipelines operate on data found in the [Uniprot] database. This collection of scripts is provided to download and process that database (or others) into a useable format.

Run `./run.sh database` to build the database tables for the metaproteomics webserver or `./run.sh index` to build the index files for the metagenomics pipeline. The top of the `run.sh` script lists some parameters you might want to change, such as the target location of the files.

The `make-on-hpc.sh` script contains information on how to run this on our own high performance computing infrastructure.

[metaproteomics]: https://github.com/unipept/unipept
[metagenomics]: https://github.com/unipept/umgap
