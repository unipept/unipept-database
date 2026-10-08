# Deploying a Unipept database

These scripts build, distribute, load and check the database a Unipept API host serves. They
orchestrate; the pipeline itself lives in `pipelines/` and the loader in `opensearch/`.

They are grouped by where they run, as unipept-api's are. `server/` holds what runs on every
server: `clone.sh`, `load.sh`, `verify.sh`, `switch.sh`, `prune.sh`, and `install.sh` and
`opensearch/install.sh`, which prepare one. `build.sh`, which runs on the build host, and
`distribute.sh`, which works on the whole fleet, are at the top, beside `lib.sh` and the
configuration examples.

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
  checks, through `check_index_whole` in `lib/checks.sh`, which `check_db_whole` makes of a
  database's directory: `build.sh` before it puts a build in place, `clone.sh` on the remote host
  before it copies and again on the copy, `load.sh` before it loads, and `switch.sh` before it
  switches. Run it by hand to check a database that is already there.

A new database on a host is therefore two steps, `build.sh` or `clone.sh` and then `load.sh`, and
serving it a third, `switch.sh`. A load that fails is rerun on its own, without building or
copying again.

`distribute.sh` does those two steps on every API server at once, from wherever it is run. See
[Distributing a database](#distributing-a-database).

`server/install.sh` installs what a server runs in `/opt/unipept-database`, laid out as a clone
lays it out, `deploy/` for `.deploy/`: `deploy/lib.sh`, `deploy/lib/` and `deploy/server/` with
`clone.sh`, `load.sh`, `verify.sh`, `switch.sh` and `prune.sh`, beside `opensearch/` and
`pipelines/lib/`. A host that only clones and serves needs no clone of this repository, the path is
the same on every host, and a script finds what it uses by the same relative path in both.
`build.sh` runs from a clone, since it builds from the source, and `distribute.sh` from wherever
its `servers.conf` is. Below, `deploy/` is that installed directory and `.deploy/` a clone's.

## Preparing a host

```sh
sudo .deploy/server/install.sh --heap 8g
```

This, and `opensearch/install.sh`, which it runs, are the only steps that need root. It prepares the
host and installs the scripts, then runs `.deploy/server/opensearch/install.sh`, which sets up
OpenSearch and can also run on its own, as root, to change a setting such as the heap. Together they
prepare everything the other scripts need, so they run without sudo:

- the `unipept` user (`DEPLOY_USER`), who builds, clones and owns the databases. The API on this
  host runs as the same user, and its own install creates it the same way, in either order;
- the tools `build.sh`, `clone.sh` and `load.sh` run, installed through apt when they are missing;
- `OUTPUT_DIR`, owned by that user. Databases, staging directories and interrupted swaps an
  earlier run as root left there are handed over too; nothing else in the directory changes owner;
- the scripts a host runs, in `/opt/unipept-database` as above, `etc/deploy.conf`, written once from
  the example and then root's to edit, since `install.sh` reads it as root, and `INSTALLED`, which
  names the commit they came from. A host takes a newer version by running `install.sh` again from
  a clone of it. Each install builds a release whole in `releases/` and puts it in place with
  `switch_release` from `lib/core.sh`: `release` is a link to it, renamed over the old one in one
  step, and `deploy`, `opensearch`, `pipelines` and `INSTALLED` are links through it. Each file a
  script opens is one whole release's, an install stopped part way leaves the one before in place,
  and nothing a clone no longer has is left behind; the release replaced stays until the next
  install, for a run that started from it; `etc/` is not touched;
- the OpenSearch instance this host loads its proteins into, configured and started.

It ends with what is left to do: fill in `deploy.conf` as root, then as `unipept` add an ssh key and a
`~/.ssh/config` entry for a clone, and for a build, clone this repository and install Rust with rustup.

Run it as root, once per host or again after changing a setting: a run that changes nothing
restarts nothing. It pins a version of OpenSearch, `OPENSEARCH_VERSION` in
`.deploy/server/opensearch/version.sh`, and holds it, so an unrelated `apt-get upgrade` cannot move
a host onto a release nothing has been tested against.

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
`deploy.conf.example`. A flag wins over that file, and the file wins over the defaults in
`lib/` for the settings the scripts share, and in each script for the settings only it has.

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
/opt/unipept-database/deploy/server/clone.sh --remote-address selma.ugent.be
```

Every script but the two installs refuses to run as root. A database written by root is one the
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
/opt/unipept-api/deploy/server/deploy.sh stop
sudo systemctl stop opensearch
```

and start them again afterwards, OpenSearch first. `--skip-checks` builds anyway.

## Loading the proteins

```sh
deploy/server/load.sh                                # the newest one under OUTPUT_DIR
deploy/server/load.sh --uniprot-version 2026-03
deploy/server/load.sh --uniprot-version 2026-03 --skip 120000000   # continue a load that stopped
```

It checks the database as `verify.sh` does, and refuses one that fails, before it loads
`tables/uniprot_entries.tsv.lz4` into `uniprot_entries-<version>`. The API queries the index of the
version this host serves, so a load of another one changes nothing the API answers, and a load that
fails can be rerun at any time. `--skip` passes over the rows a load that stopped already wrote,
and keeps the index as it is. The loader marks an index once its last row is in, and
`load.sh --check` asks for that mark, and exits 2 when OpenSearch does not say, which is not a "no".

`opensearch/load.sh`, which this calls, is the loader alone: it drops and fills the index it is
named, with none of these checks and no lock. Load through `deploy/server/load.sh`.

Loading into a version this host serves is refused while its index is loaded to the end, from the
start or continued with `--skip`: it would change what the running API answers with nothing stopped.
Switch away from it with `switch.sh` first, as any change to what the API serves goes through a
stop. Where that index is missing or was not loaded to the end, the API answers from it badly
already, and loading it is how the host gets it back, so that goes ahead. Which versions are served,
`current` says, and the API's own `deploy.sh status`, which names the index it queries. Two loads of
the same version never run at once: the second stops.

## Switching the API to another version

As `unipept`, on the host, once the version is there and its proteins are loaded:

```sh
deploy/server/switch.sh --uniprot-version 2026-03 --check      # can it switch? changes nothing
deploy/server/switch.sh --uniprot-version 2026-03
deploy/server/switch.sh --back                                 # to the version before
```

The API reads what it serves when it starts: `INDEX_LOCATION` names the suffix array through the
`current` link in `OUTPUT_DIR`, and the `.version` there names the index of its proteins,
`uniprot_entries-2026-03`. A switch moves that link while the API and OpenSearch are stopped, so
the files and the proteins always change together.

- **It checks everything first**, while both still run, and reports every problem: the API's
  `deploy.sh status` answers in the format these scripts read, the version's files, its index
  loaded to the end, the index of the version it leaves open and whole to go back to, `INDEX_LOCATION` naming `current`,
  `OUTPUT_DIR` writable for the links, no load running, the sudo rule below, and the API's own
  `deploy.sh check --index` on the new files, which covers the memory its variant needs for them. A
  host with any problem is left as it is. The one change before the stop is opening the new
  version's index where it is closed, which the API's check needs, and it is only made once
  everything else has passed. `--check` makes no change at all, so on a closed index it says the
  API's check could not run.
- **Loads, switches, prunes and installs exclude each other**, through one lock per host,
  `/run/lock/unipept-opensearch.lock`: `load.sh` holds it shared while it loads, and a switch, a
  prune or an install exclusively from its checks to its end. Whichever comes second stops, and
  says why.
- **Deploys of the API and switches exclude each other** too, through the API's own lock, at the
  path its `deploy.sh status` names: the API's `deploy`, `rollback`, `stop` and `start` hold it, and
  a switch holds it from its checks to its end, so no deploy or rollout restarts the API during a
  switch. The `deploy.sh stop` and `start` the switch runs take it over on the descriptor they
  inherit.
- **Then** it stops the API and OpenSearch, points `current` at the new version and `previous` at
  the old one, starts OpenSearch and waits for the new index, and starts the API, which waits
  until it answers `/health` and `/health/database`.
- **A start that fails, a link that cannot be moved, or an interrupt**, points the links back and
  starts both on the version it left, so the host serves what it served. It says which of the two
  it ended on.
- **Once the API serves, it closes the indices of versions older than both**, which frees their
  memory. It deletes nothing; `prune.sh` does, and takes the same lock, so it never removes a
  version a load or a switch is working on.

It knows nothing of a load balancer: take the host out of the pool first where it is in one.

OpenSearch is a system service, so stopping it takes root. `install.sh` allows `unipept` exactly
`systemctl stop opensearch` and `systemctl start opensearch` through sudo, without a password, in
`/etc/sudoers.d/unipept-opensearch`, and nothing more.

### Setting up a host for it

Once, on a new host that runs the API, as `unipept`, when its first version is there and its
proteins are loaded: point `current` at that version, and the API's `INDEX_LOCATION` through it.

```sh
ln -s uniprot-2026-03 /mnt/data/current
# in /opt/unipept-api/etc/unipept-api.env:
INDEX_LOCATION=/mnt/data/current/suffix-array
```

Then start the API on it. After that, `switch.sh` is how the version changes. A host whose
OpenSearch still holds `uniprot_entries` or `uniprot_entries-legacy`, from before the indices were
named after their version, keeps them until they are deleted by hand: nothing here knows them.

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
connection, which that server's own `~/.ssh/config` decides for its `clone.sh`, or its `deploy.conf`,
and which the preflight checks.

Nothing it does changes what the API serves: the copy lands beside the database in use, and the
load in an index of its own, so every server stays in rotation. `switch.sh` on each server switches
it.

- **It never builds.** A version the source does not have whole stops it, before any server is
  touched.
- **It is safe to rerun.** A server that has the version, or its proteins, is not given them again,
  so a run that stopped part way is finished by running it again.
- **A server whose copy fails verification is left alone**, since someone may be looking into it.
  `--replace` copies it again.
- **A server whose OpenSearch does not say whether the proteins are loaded is not loaded**, since
  a load could drop a whole index. The table marks it failed.
- **A server that fails does not stop the others.** The table says which failed, and the exit
  status is 1.

The copy and the load take hours, each over an ssh session. Run it in `tmux` or `screen`.

## Removing old versions

```sh
deploy/server/prune.sh --keep 2 --dry-run      # what it would remove
deploy/server/prune.sh --keep 2
```

Every version stays on a host until this removes it, its directory and its OpenSearch index
together, so going back to one is a switch rather than a build or a copy. A closed index costs no
memory; what old versions cost is disk.

It keeps the version `current` points at, the one `previous` points at, the one the API serves by
its `deploy.sh status`, every version newer than the oldest of those, since those are
loaded ahead of a switch still to come, and the `--keep` newest ones older than that. Without a
`current` link, or where the API's `deploy.sh status` does not say what it serves, it removes
nothing. It takes the same lock as a load and a switch.

`load.sh` warns when OpenSearch's disk is past its low watermark, 85% unless the cluster sets
another. At 95% OpenSearch makes every index read-only, and a load running then fails part way, so
the warning is the time to prune.

## Checking a database

```sh
deploy/server/verify.sh                              # the newest one under OUTPUT_DIR
deploy/server/verify.sh --uniprot-version 2026-03
deploy/server/verify.sh --index-dir /srv/data/uniprot-2026-03/suffix-array
```

As `unipept`, like the others: it checks that the files can be read by the user the API runs
as, and as root every file can.

It reports every file that is missing, empty or unreadable rather than the first, and exits 1 if any
of them is, or 3 when the database is not there at all. A missing `kmer_table.bin` is a warning: the
API runs without it and searches are slower. The list it checks is the one the API checks before it
starts, so a change has to be made on both sides.

`build-info.txt` records the UniProtKB version, the commit of this checkout, the commit of the
unipept-index clone the build used, and the sources it read. unipept-index is cloned at the tip of
its default branch, so two builds of the same UniProtKB release can differ; this file is how you
tell. It is written last, so a directory that has one is a finished build. Whether its proteins
are in OpenSearch is not something it records.

## The shared library

Every script sources `lib.sh`, which loads its parts from `lib/`. Each part says in its header what
it uses of the others.

| Part | What it holds |
| --- | --- |
| `lib/core.sh` | the shell options, `log`, `die`, `require`, `need_value`, the error trap, `switch_release` |
| `lib/config.sh` | the settings the parts share, the deploy user, reading `deploy.conf` and `key=value` lines |
| `lib/locks.sh` | the OpenSearch lock, the lock per version, and taking the API's lock |
| `lib/versions.sh` | version names, `.version`, the `current` and `previous` links |
| `lib/database.sh` | what a database holds, and how it is put in place |
| `lib/api.sh` | what this host serves, from the API's `deploy.sh status` |
| `lib/remote.sh` | the bounds on an ssh connection to another host |
| `lib/checks.sh` | what has to be true before a script changes anything: one function per check, printing `FAIL …` |

`server/install.sh` installs them as `/opt/unipept-database/deploy/lib.sh` and
`/opt/unipept-database/deploy/lib/`, root's like the scripts in `deploy/server/`.

`lib/core.sh` is the same file in every repository that deploys Unipept. Its header lists what a script's exit status means, which is the same for every script.

## What a host needs

`server/install.sh` installs all of it but Rust. For reference, or for a host prepared another way:

- `build.sh` needs `git`, `cmake` and a Rust toolchain, and the pipeline needs `curl`, `uuidgen`,
  `pigz`, `gawk`, `lz4`, `pv`, `unzip` and `xmllint`.
- `clone.sh` needs `ssh` and `scp`, and none of the build tools.
- `load.sh` needs `lz4`, `pv`, and Python with `requests` for the OpenSearch loader, and an
  OpenSearch instance at `OPENSEARCH_URL`.

`SCRATCH_DIR` holds the unipept-index clone and its cargo target, a few gigabytes. The build
itself, tables and temporary files included, goes under `OUTPUT_DIR`, so that is the volume to
size for a full UniProt build.
