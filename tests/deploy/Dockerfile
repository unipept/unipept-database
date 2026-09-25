# What .deploy/build.sh, clone.sh and opensearch/install.sh need on a host. A real ssh and a real
# scp, because what clone.sh gets wrong is where a copy lands, and a stub is written by the same
# hand as the script. cargo, cmake and sa-builder are stood in for: building the index is
# unipept-index's job and hours of it.
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git lz4 openssh-client openssh-server pv python3 python3-requests \
 && rm -rf /var/lib/apt/lists/*

# The user build.sh and clone.sh run as on a host, which .deploy/opensearch/install.sh creates
# there. They refuse root.
RUN useradd --create-home --shell /bin/bash unipept
