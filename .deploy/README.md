# Deploying a Unipept database

Two scripts build and distribute the database a Unipept API host serves. They orchestrate; the
pipeline itself lives in `pipelines/` and the loader in `opensearch/`.

- `build.sh` builds everything on this host: the tables, the suffix array, the `datastore/` layout
  the API reads, and the proteins in OpenSearch.
- `clone.sh` copies a finished database from another host and loads its proteins into the
  OpenSearch of this one. The build runs once; every other host clones the result.

## Configuration

Copy `build.conf.example` to `build.conf` and edit it. A setting already in the environment wins
over the file, and the file wins over the defaults in `lib.sh`:

```sh
cp .deploy/build.conf.example .deploy/build.conf
OUTPUT_DIR=/srv/data .deploy/build.sh          # the environment wins
```

## Running a build

```sh
.deploy/build.sh
.deploy/clone.sh --remote-address selma.ugent.be --local-ssh-key ~/.ssh/id_unipept
```

The result is `${OUTPUT_DIR}/uniprot-<version>/suffix-array/`, which holds `sa.bin`,
`proteins.bin`, `mapping.bin`, `.version`, `datastore/` and `build-info.txt`. That directory is
what the API is pointed at.

`build-info.txt` records the UniProtKB version, the commits of unipept-database and unipept-index
the build used, and the sources it read. Both repositories are cloned at the tip of their default
branch, so two builds of the same UniProtKB release can differ; this file is how you tell.

## What a host needs

`git`, `curl`, `lz4`, `pigz`, `pv`, `uuidgen`, `cmake`, a Rust toolchain, and the tools the
pipeline itself checks for. `clone.sh` needs `ssh` and `scp` instead of the build tools. The
OpenSearch loader needs Python with `requests` (`opensearch/requirements.txt`) and an OpenSearch
instance at `OPENSEARCH_URL`.
