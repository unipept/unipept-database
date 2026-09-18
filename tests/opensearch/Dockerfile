# Everything initialize_opensearch.sh needs on a host, at the versions the script expects.
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl lz4 pv python3 python3-requests \
 && rm -rf /var/lib/apt/lists/*
