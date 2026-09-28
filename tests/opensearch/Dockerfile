# Everything opensearch/load.sh needs on a host, at the versions the script expects.
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl lz4 pv python3 python3-requests \
 && rm -rf /var/lib/apt/lists/*

# The user the .deploy scripts run as on a host. They refuse root, and .deploy/prune.sh is tested here
# because it removes indices from a real OpenSearch.
RUN useradd --create-home unipept
