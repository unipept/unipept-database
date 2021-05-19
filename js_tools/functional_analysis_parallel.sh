#! /bin/bash

INPUT="$1"
OUTPUT="$2"
# How many CPU's should be used to process this file?
N="$3"

node SplitFunctionalAnalysis.js "$INPUT" "$OUTPUT" "$N"
find . -name "*.tmp" | parallel -j16 -I% --max-args 1 node FunctionalAnalysisPeptides % %.output
cat *.output > all.tsv
rm *.output *.tmp
