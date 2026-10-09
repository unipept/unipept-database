# Fleet rehearsal

A release, rehearsed on a fleet in containers before it is done on the real hosts. The suites in
`tests/` each test one script and stand in for what is around it; this runs every piece for real,
together: both repositories' installs, ssh between hosts, OpenSearch, HAProxy, and the API's latest
release, its scripts and its binary. Only the data is not real: it is the seam suite's fixtures.

## Running it

From the Actions tab, **Fleet rehearsal**, **Run workflow**. It takes about half an hour, and keeps
every host's logs as the `fleet-logs` artifact.

By hand, on an x86_64 machine with Docker:

```sh
sudo sysctl -w vm.max_map_count=262144     # OpenSearch does not start below it
tests/fleet/run.sh
```

`FLEET_LOGS=DIR` keeps the logs there; `FLEET_KEEP=1` leaves the containers running, to look
around in with `docker exec -it fleet-s1 bash`.

## The fleet

One image for every host, Ubuntu 24.04 with systemd and sshd on port 2222 only, so a script that
does not follow `~/.ssh/config` fails.

| Host | What is installed |
| --- | --- |
| `build` | this repository's `server/install.sh`; builds the databases |
| `s1`, `s2` | this repository's `server/install.sh` and the API's `server/install.sh`; serve the API |
| `lb` | HAProxy and the API's `loadbalancer/install.sh`; where `distribute.sh` and `rollout.sh` run |

## The flow

The release runbook, in order. Each step's checks say what it has to leave behind.

1. Start the fleet, with this checkout and the latest API release's checkout on every host.
2. The installs, each run twice, and the keys and `~/.ssh/config` an operator sets up.
3. `build.sh` over the fixtures as UniProtKB 2026-09, with the real unipept-index and sa-builder.
4. `distribute.sh` from `lb` to `s1` and `s2`, then again, which does nothing.
5. On each server, `current` and `INDEX_LOCATION` set by hand and the API deployed: the release
   before the latest, or the latest while it is the only one from 2.7.0.
6. HAProxy and `loadbalancer/install.sh`, whose audit has to pass. A poller then asks a fixture
   peptide through HAProxy every half second until the end.
7. `rollout.sh` to the latest release. No request may fail.
8. A second build, as 2026-10, distributed beside the first.
9. Each server drained, switched to 2026-10 with `switch.sh`, and put back. No request may fail.

What it does not cover is what the suites already do: failures, rollbacks, interrupts and the
rollout's mail.
