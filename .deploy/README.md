# Deploying a Unipept database

Two scripts build and distribute the database a Unipept API host serves. They orchestrate; the
pipeline itself lives in `pipelines/` and the loader in `opensearch/`.

- `build.sh` builds everything on this host: the tables, the suffix array, the `datastore/` layout
  the API reads, and the proteins in OpenSearch.
- `clone.sh` copies a finished database from another host and loads its proteins into the
  OpenSearch of this one. The build runs once; every other host clones the result.
- `verify.sh` checks a finished database against the files the API needs. The other two make
  the same file checks themselves before they change anything the API serves: `build.sh` before
  it loads OpenSearch, `clone.sh` on the remote host before it copies and again on the copy. Run
  it by hand to check a database that is already there.

## Preparing a host

```sh
sudo .deploy/opensearch/install.sh --heap 8g
```

Installs and configures the OpenSearch instance this host loads its proteins into, and starts it.
Run it as root, once per host or again after changing a setting: a run that changes nothing
restarts nothing. It pins a version and holds it, also on a host that already had that version,
so an unrelated `apt-get upgrade` cannot move a host onto a release nothing has been tested
against.

It keeps the data and log paths the existing configuration names, so a host set up by hand with
its data on another volume keeps it there. `--data-dir` and `--log-dir` point the configuration
elsewhere; they do not move what is already there. It waits for the instance on the address and
port it configured.

The instance binds to localhost and runs with the security plugin off, which is what the loader
and the API both expect. That pair is only safe while nothing outside the host can reach it, so
change the bind address only together with turning the security plugin back on.

The heap is the one number a host decides, and it defaults low. This host also serves the API,
which holds the index resident, and `unipept-api/.deploy` sizes that against the memory it can
see: heap taken here is memory that sizing does not know about. A later run without `--heap`
keeps the heap the host already has.

## Configuration

Copy `deploy.conf.example` to `deploy.conf` and edit it. A flag wins over that file, and the file
wins over the defaults in `lib.sh` for the settings both scripts have, and in `build.sh` or
`clone.sh` for the settings one of them has:

```sh
cp .deploy/deploy.conf.example .deploy/deploy.conf
.deploy/build.sh --output-dir /srv/data        # the flag wins
```

`deploy.conf.example` lists only what a host has to decide. It holds no defaults, so it cannot
disagree with the scripts.

## Running a build

```sh
.deploy/build.sh
.deploy/clone.sh --remote-address selma.ugent.be --local-ssh-key ~/.ssh/id_unipept
```

The result is `${OUTPUT_DIR}/uniprot-<version>/suffix-array/`, which holds `sa.bin`,
`proteins.bin`, `mapping.bin`, `.version`, `datastore/` and `build-info.txt`. That directory is
what the API is pointed at. The version in the name is the one the pipeline wrote to `.version`,
so the two always agree.

Beside it, `${OUTPUT_DIR}/uniprot-<version>/tables/uniprot_entries.tsv.lz4` is what `clone.sh`
reads to fill another host's OpenSearch. Keep it on the build host for as long as hosts still
clone that version. The rest of `tables/` is removed during the build.

A build writes to `${OUTPUT_DIR}/.build/` and is renamed into place at the end, so the database
this host serves is only ever replaced by a finished one. A build whose version already exists
stops and keeps its result in `.build/`; `--replace` lets it take the place of the old one. The
same holds for `clone.sh`, through `${OUTPUT_DIR}/.clone/`. Both therefore need room for two
databases at the moment they finish.

## Checking a database

```sh
.deploy/verify.sh                              # the newest one under OUTPUT_DIR
.deploy/verify.sh --uniprot-version 2026-03
.deploy/verify.sh --index-dir /srv/data/uniprot-2026-03/suffix-array
```

It reports every file that is missing, empty or unreadable rather than the first, and exits
non-zero if any of them is. A missing `kmer_table.bin` is a warning: the API runs without it and
searches are slower. The list it checks is the one `unipept-api/.deploy/lib.sh` starts a service
against, so a change on either side has to be made on both.

`build-info.txt` records the UniProtKB version, the commit of this checkout, the commit of the
unipept-index clone the build used, and the sources it read. unipept-index is cloned at the tip of
its default branch, so two builds of the same UniProtKB release can differ; this file is how you
tell. It is written after the proteins are loaded, so a directory that has one is complete.

## What a host needs

Both scripts need `lz4`, `pv`, and Python with `requests` (`opensearch/requirements.txt`) for the
OpenSearch loader, and an OpenSearch instance at `OPENSEARCH_URL`.

`build.sh` also needs `git`, `cmake` and a Rust toolchain for its own work, plus what the pipeline
checks for when it starts: `curl`, `uuidgen`, `pigz`, `gawk` and `xmllint`. `clone.sh` needs `ssh`
and `scp`, and none of the build tools.

`SCRATCH_DIR` holds the unipept-index clone and its cargo target, a few gigabytes. The build
itself, tables and temporary files included, goes under `OUTPUT_DIR`, so that is the volume to
size for a full UniProt build.
