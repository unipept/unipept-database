#!/bin/bash

AMOUNT_OF_TIMINGS=10

timings=$(mktemp)

for i in $(seq 1 $AMOUNT_OF_TIMINGS); do
    cat data/uniprot_sprot.dat | time ./target/release/dat-parser --threads 4 > /dev/null 2> $timings
    cat $timings | grep -Eo '[0-9\.]+ real' | cut -d' ' -f1
done | awk '{ sum += $1 } END { print sum/NR }'

rm $timings
