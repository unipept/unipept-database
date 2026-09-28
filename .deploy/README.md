# Deploying a Unipept database

Four scripts build, distribute, load and check the database a Unipept API host serves. They
orchestrate; the pipeline itself lives in `pipelines/` and the loader in `opensearch/`.

- `build.sh` builds a database on this host: the tables, the suffix array and the `datastore/`
  layout the API reads.
- `clone.sh` copies a finished database from another host. The build runs once; every other host
  clones the result.
- `load.sh` loads the proteins of a database that is in place into the OpenSearch of this host,
  as an index of that version beside the one the API queries. With `--activate` it then switches
  the API to it; that is the only step that changes what the API's protein search answers.
- `verify.sh` checks a finished database against the files the API needs. The others make the same
  checks, through the same `verify_database` in `lib.sh`: `build.sh` before it puts a build in
  place, `clone.sh` on the remote host before it copies and again on the copy, and `load.sh`
  before it loads. Run it by hand to check a database that is already there.

A new database on a host is therefore two steps, `build.sh` or `clone.sh` and then `load.sh`. A
load that fails is rerun on its own, without building or copying again.

## Preparing a host

```sh
sudo .deploy/opensearch/install.sh --heap 8g
```

This is the only step that needs root. It prepares everything the other scripts need, so they
run without sudo:

- the `unipept` user (`DEPLOY_USER`), who builds, clones and owns the databases. The API on this
  host runs as the same user, and its own install creates it the same way, in either order;
- the tools `build.sh` and `clone.sh` run, installed through apt when they are missing;
- `OUTPUT_DIR`, owned by that user. Databases, staging directories and interrupted swaps an
  earlier run as root left there are handed over too; nothing else in the directory changes owner;
- the OpenSearch instance this host loads its proteins into, configured and started.

It ends with what is left to do as `unipept`: clone this repository, install Rust with rustup for
a build, and add an ssh key for a clone.

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

The heap is the one number a host decides, and it defaults low; `OPENSEARCH_HEAP` in the script
says why. A later run without `--heap` keeps the heap the host already has.

Every index is set to hold no replica, since a single node has nowhere to put one and a replica
it cannot place keeps the cluster yellow. That includes the query insights plugin's
`top_queries-*` indices, which it would otherwise create with one, so its exporter to a local
index is off.

## Configuration

Copy `deploy.conf.example` to `deploy.conf` and edit it. A flag wins over that file, and the file
wins over the defaults in `lib.sh` for the settings the scripts share, and in each script for the
settings only it has:

```sh
cp .deploy/deploy.conf.example .deploy/deploy.conf
.deploy/build.sh --output-dir /srv/data        # the flag wins
```

`deploy.conf.example` lists only what a host has to decide. It holds no defaults, so it cannot
disagree with the scripts.

## Running a build

As `unipept`, from a clone of this repository that `unipept` owns:

```sh
sudo -iu unipept
.deploy/build.sh
.deploy/clone.sh --remote-address selma.ugent.be --local-ssh-key ~/.ssh/id_unipept
```

Both refuse to run as root, as do `load.sh` and `verify.sh`. A database written by root is one the
next run as `unipept` cannot replace, and one whose check that the API can read it passes only
because root reads everything.

The result is `${OUTPUT_DIR}/uniprot-<version>/suffix-array/`, which holds `sa.bin`,
`proteins.bin`, `mapping.bin`, `.version`, `datastore/` and `build-info.txt`. That directory is
what the API is pointed at. The version in the name is the one the pipeline wrote to `.version`,
so the two always agree.

Beside it, `${OUTPUT_DIR}/uniprot-<version>/tables/uniprot_entries.tsv.lz4` is what `load.sh`
reads to fill OpenSearch, on this host and on every host that clones it. Keep it for as long as
that version may be loaded again. The rest of `tables/` is removed during the build.

A build writes to `${OUTPUT_DIR}/.build/` and is renamed into place at the end, so the database
this host serves is only ever replaced by a finished one. A build whose version already exists
stops and keeps its result in `.build/`; `--replace` lets it take the place of the old one. The
same holds for `clone.sh`, through `${OUTPUT_DIR}/.clone/`. Both therefore need room for two
databases at the moment they finish.

## Loading the proteins

```sh
.deploy/load.sh                                # the newest one under OUTPUT_DIR
.deploy/load.sh --uniprot-version 2026-03
.deploy/load.sh --uniprot-version 2026-03 --skip 120000000   # continue a load that stopped
.deploy/load.sh --uniprot-version 2026-03 --activate         # and switch the API to it
```

It checks the database as `verify.sh` does, and refuses one that fails, before it loads
`tables/uniprot_entries.tsv.lz4` into `uniprot_entries-<version>`. The API queries
`uniprot_entries`, which is an alias, so a load changes nothing the API answers, and a load that
fails can be rerun at any time. `--skip` passes over the rows a load that stopped already wrote,
and keeps the index as it is.

The switch is `opensearch/activate.sh`, which `--activate` runs after the load:

- it points `uniprot_entries` at the new index in one request, so the API never finds the name
  missing. It refuses an index that is not there, holds no documents, or was not loaded to the
  end: the loader marks an index once its last row is in, and `load.sh --check` asks for that mark;
- it closes the index it switched away from, which frees the memory that holds and keeps its data.
  Going back is activating that one again, which opens it. It deletes nothing: see
  [Removing old versions](#removing-old-versions);
- on a host loaded before versioned indices, where `uniprot_entries` is still an index, the first
  switch keeps that index as `uniprot_entries-legacy`, by a clone that shares its files, so there
  is something to go back to from the start.

Switching the index is only half of moving the API to a new version: its files are the other
half, `INDEX_LOCATION` in its environment file. Until the API's rollout switches both together,
`--activate` moves only the proteins, as a load did before.

Reloading the version the alias points at is refused, because the loader drops it first and the API
would search a partial index until it finishes. `--replace-live` does it anyway.

## Removing old versions

```sh
.deploy/prune.sh --keep 2 --dry-run      # what it would remove
.deploy/prune.sh --keep 2
```

Every version stays on a host until this removes it, its directory and its OpenSearch index
together, so going back to one is a switch rather than a build or a copy. A closed index costs no
memory; what old versions cost is disk.

It keeps the version the API queries, which is the one the `uniprot_entries` alias points at, every
newer version, since those are loaded ahead of a switch still to come, and the `--keep` newest ones
older than it. The old index kept at a host's first switch, `uniprot_entries-legacy`, counts as the
oldest. Without an alias it removes nothing, since which version the API queries is then not known.

`load.sh` warns when OpenSearch's disk is past its low watermark, 85% unless the cluster sets
another. At 95% OpenSearch makes every index read-only, and a load running then fails part way, so
the warning is the time to prune.

## Checking a database

```sh
.deploy/verify.sh                              # the newest one under OUTPUT_DIR
.deploy/verify.sh --uniprot-version 2026-03
.deploy/verify.sh --index-dir /srv/data/uniprot-2026-03/suffix-array
```

As `unipept`, like the others: it checks that the files can be read by the user the API runs
as, and as root every file can.

It reports every file that is missing, empty or unreadable rather than the first, and exits
non-zero if any of them is. A missing `kmer_table.bin` is a warning: the API runs without it and
searches are slower. The list it checks is the one `unipept-api/.deploy/lib.sh` starts a service
against, so a change on either side has to be made on both.

`build-info.txt` records the UniProtKB version, the commit of this checkout, the commit of the
unipept-index clone the build used, and the sources it read. unipept-index is cloned at the tip of
its default branch, so two builds of the same UniProtKB release can differ; this file is how you
tell. It is written last, so a directory that has one is a finished build. Whether its proteins
are in OpenSearch is not something it records.

## What a host needs

`install.sh` installs all of it but Rust. For reference, or for a host prepared another way:

- `build.sh` needs `git`, `cmake` and a Rust toolchain, and the pipeline needs `curl`, `uuidgen`,
  `pigz`, `gawk`, `lz4`, `pv`, `unzip` and `xmllint`.
- `clone.sh` needs `ssh` and `scp`, and none of the build tools.
- `load.sh` needs `lz4`, `pv`, and Python with `requests` for the OpenSearch loader, and an
  OpenSearch instance at `OPENSEARCH_URL`.

`SCRATCH_DIR` holds the unipept-index clone and its cargo target, a few gigabytes. The build
itself, tables and temporary files included, goes under `OUTPUT_DIR`, so that is the volume to
size for a full UniProt build.
