# Deploying a Unipept database

These scripts build, distribute, load and check the database a Unipept API host serves. They
orchestrate; the pipeline itself lives in `pipelines/` and the loader in `opensearch/`.

- `build.sh` builds a database on this host: the tables, the suffix array and the `datastore/`
  layout the API reads.
- `clone.sh` copies a finished database from another host. The build runs once; every other host
  clones the result.
- `load.sh` loads the proteins of a database that is in place into the OpenSearch of this host,
  as an index of that version beside the one the API queries. It changes nothing the API answers.
- `switch.sh` switches the API on this host to another version it holds, its files and its
  proteins together, stopping the API and OpenSearch to do so. See
  [Switching the API to another version](#switching-the-api-to-another-version).
- `verify.sh` checks a finished database against the files the API needs. The others make the same
  checks, through the same `verify_database` in `lib.sh`: `build.sh` before it puts a build in
  place, `clone.sh` on the remote host before it copies and again on the copy, and `load.sh`
  before it loads. Run it by hand to check a database that is already there.

A new database on a host is therefore two steps, `build.sh` or `clone.sh` and then `load.sh`, and
serving it a third, `switch.sh`. A load that fails is rerun on its own, without building or
copying again.

`distribute.sh` does those two steps on every API server at once, from wherever it is run. See
[Distributing a database](#distributing-a-database).

`install.sh` installs every script but `build.sh` in `/opt/unipept-database/bin`, so a host that
only clones and serves needs no clone of this repository, and the path is the same on every host.
`build.sh` runs from a clone, since it builds from the source. Below, `bin/` is that installed
directory and `.deploy/` a clone's.

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
- the scripts a host runs, in `/opt/unipept-database`: `bin/` with `clone.sh`, `load.sh`,
  `verify.sh` and `prune.sh`, what they call beside it, `etc/deploy.conf`, written once from the
  example and then root's to edit, since `install.sh` reads it as root, and `INSTALLED`, which names
  the commit they came from. A host takes a newer version by running `install.sh` again from a clone
  of it;
- the OpenSearch instance this host loads its proteins into, configured and started.

It ends with what is left to do: fill in `deploy.conf` as root, then as `unipept` add an ssh key for
a clone, and for a build, clone this repository and install Rust with rustup.

Run it as root, once per host or again after changing a setting: a run that changes nothing
restarts nothing. It pins a version of OpenSearch, `OPENSEARCH_VERSION` in
`.deploy/opensearch/version.sh`, and holds it, so an unrelated `apt-get upgrade` cannot move a host
onto a release nothing has been tested against.

Raising that pin is how a host is kept patched: run it again, and it upgrades an older release of
the same major version to the pin, keeping the configuration it writes, and restarts OpenSearch. The
API's protein search pauses while that happens, so take the host out of the pool first. It refuses,
before it changes anything on the host, a newer release than the pin, since OpenSearch cannot go
back, and another major version, since that upgrade cannot be undone and is a step of its own.

It also gives systemd a drop-in for OpenSearch,
`/etc/systemd/system/opensearch.service.d/unipept.conf`: ten minutes to start instead of the
package's 75 seconds, and a new start 30 seconds after a failure. Unattended upgrades restart
OpenSearch when a library it uses is updated, while they are busy with the same disk, and on a host
whose index is not in the page cache that start used to run out and was never tried again. A host
that only gains the drop-in is reloaded, not restarted.

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

A host's settings are in `/opt/unipept-database/etc/deploy.conf`, which `install.sh` writes from
`deploy.conf.example`. A flag wins over that file, and the file wins over the defaults in `lib.sh`
for the settings the scripts share, and in each script for the settings only it has.

The installed scripts and `build.sh` in a clone read that same file, so a build host has one set of
settings. A clone with a `.deploy/deploy.conf` of its own reads that one instead, which is how a
clone is run on a machine without an install:

```sh
cp .deploy/deploy.conf.example .deploy/deploy.conf
.deploy/build.sh --output-dir /srv/data        # the flag wins
```

`deploy.conf.example` lists only what a host has to decide. It holds no defaults, so it cannot
disagree with the scripts.

## Running a build

As `unipept`: a build from a clone of this repository that `unipept` owns, a clone from the
installed scripts:

```sh
sudo -iu unipept
.deploy/build.sh                                                   # in the clone
/opt/unipept-database/bin/clone.sh --remote-address selma.ugent.be --local-ssh-key ~/.ssh/id_unipept
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
databases at the moment they finish. Neither replaces the version this host serves, whose files the
running API has open: switch away from it with `switch.sh` first.

Before it removes what an earlier build left in `.build/`, `build.sh` checks the host has room for
the build, and stops, naming every problem, when it does not:

- the API is running, or OpenSearch is: building the suffix array takes more memory than a host
  that serves them has left, and the kernel kills it hours in;
- less than 1.5 times the size of the newest database under `OUTPUT_DIR` is free on its disk, or
  less than 1.2 times that size in memory. The previous database is the measure of the next; a
  first build has none, and is only checked for the API and OpenSearch.

Stop both before building:

```sh
/opt/unipept-api/lib/deploy.sh stop
sudo systemctl stop opensearch
```

and start them again afterwards, OpenSearch first. `--skip-checks` builds anyway.

## Loading the proteins

```sh
.deploy/load.sh                                # the newest one under OUTPUT_DIR
.deploy/load.sh --uniprot-version 2026-03
.deploy/load.sh --uniprot-version 2026-03 --skip 120000000   # continue a load that stopped
```

It checks the database as `verify.sh` does, and refuses one that fails, before it loads
`tables/uniprot_entries.tsv.lz4` into `uniprot_entries-<version>`. The API queries the index of the
version this host serves, so a load of another one changes nothing the API answers, and a load that
fails can be rerun at any time. `--skip` passes over the rows a load that stopped already wrote,
and keeps the index as it is. The loader marks an index once its last row is in, and
`load.sh --check` asks for that mark.

`opensearch/load.sh`, which this calls, is the loader alone: it drops and fills the index it is
named, with none of these checks and no lock. Load through `bin/load.sh`.

Loading into a version this host serves is refused while its index is loaded to the end, from the
start or continued with `--skip`: it would change what the running API answers with nothing stopped.
Switch away from it with `switch.sh` first, as any change to what the API serves goes through a stop.
Where that index is missing or was not loaded to the end, the API answers from it badly already, and
loading it is how the host gets it back, so that goes ahead. Which versions are served, `current`
says, `INDEX_LOCATION` where it names a version's directory itself, and an alias `uniprot_entries` an
earlier release left. Two loads of the same version never run at once: the second stops.

## Switching the API to another version

As `unipept`, on the host, once the version is there and its proteins are loaded:

```sh
bin/switch.sh --uniprot-version 2026-03 --check      # can it switch? changes nothing
bin/switch.sh --uniprot-version 2026-03
bin/switch.sh --back                                 # to the version before
```

The API reads what it serves when it starts: `INDEX_LOCATION` names the suffix array through the
`current` link in `OUTPUT_DIR`, and the `.version` there names the index of its proteins,
`uniprot_entries-2026-03`. A switch moves that link while the API and OpenSearch are stopped, so
the files and the proteins always change together.

- **It checks everything first**, while both still run, and reports every problem: the API
  installed is unipept-api 2.7.0 or newer, the version's files, its index loaded to the end, the
  index of the version it leaves open and whole to go back to, `INDEX_LOCATION` naming `current`, `OUTPUT_DIR` writable for
  the links, no load running, the sudo rule below, and the API's own `deploy.sh check --index` on
  the new files, which covers the memory its variant needs for them. A host with any problem is
  left as it is. The one change before the stop is opening the new version's index where it is
  closed, which the API's check needs, and it is only made once everything else has passed.
  `--check` makes no change at all, so on a closed index it says the API's check could not run.
- **Loads and switches exclude each other**, through one lock per host,
  `/run/lock/unipept-opensearch.lock` unless `OPENSEARCH_LOCK` says otherwise: `load.sh` holds it
  shared while it loads, and a switch exclusively from its checks to its end. Whichever comes
  second stops, and says why.
- **Then** it stops the API and OpenSearch, points `current` at the new version and `previous` at
  the old one, starts OpenSearch and waits for the new index, and starts the API, which waits
  until it answers `/health` and `/health/database`.
- **A start that fails, a link that cannot be moved, or an interrupt**, points the links back and
  starts both on the version it left, so the host serves what it served. It says which of the two
  it ended on.
- **Once the API serves, it removes the alias `uniprot_entries`** an earlier release of these
  scripts left, which only an API from before versioned indices queried, and **closes the indices
  of versions older than both**, which frees their memory. It refuses to switch while the API
  `deploy.sh rollback` would go back to is older than 2.7.0: that one queries the alias, which
  holds the proteins of the version served before any switch, and after one would serve the new
  files with them. Removing `bin/unipept-api.previous`, as `unipept`, gives up that rollback. It deletes nothing; `prune.sh` does, and
  takes the same lock, so it never removes a version a load or a switch is working on.

It knows nothing of a load balancer: take the host out of the pool first where it is in one.

OpenSearch is a system service, so stopping it takes root. `install.sh` allows `unipept` exactly
`systemctl stop opensearch` and `systemctl start opensearch` through sudo, without a password, in
`/etc/sudoers.d/unipept-opensearch`, and nothing more.

### Setting up a host for it

Once, on a host that runs the API, as `unipept`:

```sh
bin/migrate.sh
```

It points `current` at the version the API's `INDEX_LOCATION` names, and, on a host loaded before
versioned indices, keeps the proteins it serves in the index named after that version too: a clone
of `uniprot_entries`, or of `uniprot_entries-legacy` where an alias of that name points there, as
an earlier release of these scripts left it, which costs no copy. Neither changes what the API
serves, and running it again changes nothing on a host that is set up. What is left is one line in the API's environment file, which it asks for:

```sh
INDEX_LOCATION=/mnt/data/current/suffix-array
```

It names the same files, so nothing changes until the API next starts. After that, `switch.sh` is
how the version changes.

## Distributing a database

Once a build has finished on one host, from any machine that reaches the API servers over ssh as
`unipept`:

```sh
cp .deploy/servers.conf.example .deploy/servers.conf     # once: the servers
.deploy/distribute.sh --uniprot-version 2026-03 --from selma.ugent.be
```

It checks that the source has the version whole, then that every server answers, has the scripts
installed, and, where it needs a copy, could make one: `clone.sh --check` there, which checks that
server's settings, its key, and that it reaches the source and finds the version whole. All of that
before it touches any server. Then, one server at a time, it copies the version with that server's
own `clone.sh` where the server does not have it, and loads it with that server's own `load.sh`
where it is not loaded to the end. Where each server keeps its databases, and how it reaches the
source, is that server's own installed `deploy.conf`. It ends with a table of what each server had
and what was done.

It logs in to the source and the servers as `unipept`, or `--ssh-user`, and leaves the port and the
key to `~/.ssh/config` on the machine it runs on, as unipept-api's rollout does: a host reached on
another port says so there, once, for both. How each server then reaches the source is another
connection, which that server's `deploy.conf` decides for its `clone.sh`, and which the preflight
checks.

Nothing it does changes what the API serves: the copy lands beside the database in use, and the
load in an index of its own, so every server stays in rotation. `switch.sh` on each server switches
it.

- **It never builds.** A version the source does not have whole stops it, before any server is
  touched.
- **It is safe to rerun.** A server that has the version, or its proteins, is not given them again,
  so a run that stopped part way is finished by running it again.
- **A server whose copy fails verification is left alone**, since someone may be looking into it.
  `--replace` copies it again.
- **A server that fails does not stop the others.** The table says which failed, and the exit
  status is 1.

The copy and the load take hours, each over an ssh session. Run it in `tmux` or `screen`.

## Removing old versions

```sh
.deploy/prune.sh --keep 2 --dry-run      # what it would remove
.deploy/prune.sh --keep 2
```

Every version stays on a host until this removes it, its directory and its OpenSearch index
together, so going back to one is a switch rather than a build or a copy. A closed index costs no
memory; what old versions cost is disk.

It keeps the version `current` points at, the one `previous` points at, the one `INDEX_LOCATION`
names where it names one rather than going through `current`, every version newer than the oldest of
those, since those are loaded ahead of a switch still to come, and the `--keep` newest ones older
than that. What a host loaded before versioned indices kept, `uniprot_entries-legacy` and
`uniprot_entries` itself, counts as the oldest, and only once nothing may still need it: the API
installed is unipept-api 2.7.0 or newer, and so is the one `deploy.sh rollback` would go back to,
both of which query the index of the version they serve, `INDEX_LOCATION` goes through `current`,
and that index is open and loaded to the end. Until then it may be the only copy of the proteins an
API serves. Whatever an alias of the old name still points at is kept too. Without a `current` link, or with API settings
it cannot read, it removes nothing. It takes the same lock as a load and a switch, and `migrate.sh`
takes it too.

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

It reports every file that is missing, empty or unreadable rather than the first, and exits 1 if any
of them is, or 3 when the database is not there at all. A missing `kmer_table.bin` is a warning: the
API runs without it and searches are slower. The list it checks is the one
`unipept-api/.deploy/lib.sh` starts a service against, so a change on either side has to be made on
both.

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
