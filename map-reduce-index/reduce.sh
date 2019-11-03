#!/bin/sh
INTDIR=../small/intermediate
TABDIR=../small/tables
ACIDS=ACDEFGHIKLMNPQRSTVWY
zcat $INTDIR/sequence_taxon.[$ACIDS].tsv.gz | umgap buildindex > $TABDIR/index
