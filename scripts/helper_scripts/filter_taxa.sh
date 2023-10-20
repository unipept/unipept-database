#!/usr/bin/env bash

CURRENT_LOCATION="${BASH_SOURCE%/*}"

# First argument to this script is a list delimited by comma's of all taxa that should be retained from the complete
# database. If the given ID is 1, then we don't apply any filter at all and report all entries from the provided
# index.
TAXA="$1"
DATABASE_INDEX="$2"
TMP_DIR="$3"
LINEAGE_ARCHIVE="$4"

mkdir -p "$TMP_DIR"

filter_taxa() {
	QUERY=$(echo "\s$1\s" | sed "s/,/\\\s\\\|\\\s/g")
	RESULT=$(lz4 -dc "$LINEAGE_ARCHIVE" | grep "$QUERY" | cut -f1 | sort -n | uniq | tr '\n' ',')
	echo "$RESULT"
}

if [[ $TAXA != "1" ]]
then
  TAXA=$(filter_taxa "$TAXA")

  # This associative array maps a filename upon the taxa that should be queried within this file
  QUERIES=( $(echo "$TAXA" | tr "," "\n" | node "$CURRENT_LOCATION/TaxaByChunk.js" "$DATABASE_INDEX" "$TMP_DIR") )

  if [[ ${#QUERIES[@]} -gt 0 ]]
  then
    parallel --jobs 8 --max-args 2 "cat {2} | lz4 -dc | sed 's/$/$/' | grep -F -f {1} | sed 's/\$$//'" ::: "${QUERIES[@]}"
  fi
else

  # If the root ID has been passed to this script, we simply print out all database items (without filtering).
  find "$DATABASE_INDEX" -name "*.chunk.lz4" | xargs lz4 -dc
fi

# Remove temporary files
IDX=0
for FILE in "${QUERIES[@]}"
do
  MOD=$((IDX % 2))
  if [[ MOD -eq 0 ]]
  then
	  rm -rf "$FILE"
  fi
  (( IDX++ ))
done
