#!/bin/sh
TABDIR="/user/data/gent/gvo000/gvo00038/vsc41079/data/tables"
INTDIR="/kyukon/scratch/gent/vo/000/gvo00038/intermediate/"
ACIDS=ACDEFGHIKLMNPQRSTVWY
zcat $INTDIR/sequence_taxon.[$ACIDS].tsv.gz | umgap buildindex > $TABDIR/index
