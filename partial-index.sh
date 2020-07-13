#!/bin/bash
JAR=target/unipept-0.0.1-SNAPSHOT.jar
PAC=org.unipept.tools
TABDIR=data/tables
ACIDS=ACDEFGHIKLMNPQRSTVWY

for PREFIX in A C D E F G H I K L M N P Q R S T V W Y; do
	pv -N $PREFIX $TABDIR/uniprot_entries.tsv.gz \
		| gunzip \
		| cut -f4,7 \
		| grep "^[0-9]*	[$ACIDS]*$" \
		| umgap splitkmers \
		| sed -n "s/^$PREFIX//p" \
		| LC_ALL=C sort --parallel=16 -S 10G -T /data/tempfs \
		| sed "s/^/$PREFIX/"
done \
		| umgap joinkmers $TABDIR/taxons.tsv \
		| tee >(cut -d'	' -f3 | python frequency.py $TABDIR/frequencies.txt) \
		| cut -d'	' -f1,2 \
		| umgap buildindex \
		> $TABDIR/9-mer.index
