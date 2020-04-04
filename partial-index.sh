#!/bin/bash
JAR=target/unipept-0.0.1-SNAPSHOT.jar
PAC=org.unipept.tools
TABDIR=index-creation
ACIDS=ACDEFGHIKLMNPQRSTVWY

{
	start="$(date +%s)"
	while sleep 30s; do
		now="$(date +%s)"
		printf '%s\t%d\t%d\n' "$(date -Is)" "$((now - start))" "$(df --output=used /data/tempfs | tail -1 | tr -d ' ')"
	done > memtrace
} &
memtrace="$!"

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
		| java -Xms3g -Xmx3g -cp ${JAR} ${PAC}.LineagesSequencesTaxons2LCAs <(zcat $TABDIR/lineages.tsv.gz) \
		| umgap buildindex \
		> $TABDIR/9-mer.index

kill "$memtrace"
