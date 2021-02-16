#!/bin/sh
set -e
self="$$"

# --------------------------------------------------------------------
# configuration

PEPTIDE_MIN_LENGTH=5 # What is the minimum length (inclusive) for tryptic peptides?"
PEPTIDE_MAX_LENGTH=50 # What is the maximum length (inclusive) for tryptic peptides?"
KMER_LENGTH=9 # What is the length (k) of the K-mer peptides?
TABDIR="./data/tables" # Where should I store the final TSV files (large, single-write)?
INTDIR="./data/intermediate" # Where should I store intermediate TSV files (large, single-write, multiple-read?
TAXDIR="./data/taxon" # Where should I store and extract the downloaded taxon zip (small, single-write, single-read)?
SRCDIR="./data/sources" # Where should I store the downloaded source xml files (large, single-write, single-read)?
JAVA_MEM="6g" # How much memory should Java use?
ENTREZ_BATCH_SIZE=1000 # Which batch size should I use for communication with Entrez?
CMD_SORT="sort --buffer-size=80% --parallel=4" # Which sort command should I use?
CMD_GZIP="gzip -" # Which pipe compression command should I use?

SOURCES='swissprot https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.xml.gz'
#trembl https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_trembl.xml.gz'

# --------------------------------------------------------------------
# hopeful constants

ENTREZ_URL="https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
TAXON_URL="https://ftp.ncbi.nih.gov/pub/taxonomy/taxdmp.zip"
EC_CLASS_URL="http://ftp.ebi.ac.uk/pub/databases/enzyme/enzclass.txt"
EC_NUMBER_URL="http://ftp.ebi.ac.uk/pub/databases/enzyme/enzyme.dat"
GO_TERM_URL="http://geneontology.org/ontology/go-basic.obo"
INTERPRO_URL="http://ftp.ebi.ac.uk/pub/databases/interpro/entry.list"

# --------------------------------------------------------------------
# setup directory for temporary files

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT KILL

# --------------------------------------------------------------------
# utility functions

checkdep() {
    which $1 > /dev/null 2>&1 || hash $1 > /dev/null 2>&1 || {
        echo "Unipept backend requires ${2:-$1} to be installed." >&2
        exit 1
    }
}

log() { echo "$(date +'[%s (%F %T)]')" "$@"; }

java_() {
	if [ ! -f "target/unipept-0.0.1-SNAPSHOT.jar" ]; then mvn package; fi
	c="$1"
	shift
	java -Xms"$JAVA_MEM" -Xmx"$JAVA_MEM" \
		-cp "target/unipept-0.0.1-SNAPSHOT.jar" org.unipept.tools."$c" "$@"
}

gz() {
	fifo="$TMP/$(uuidgen)-$(basename "$1")"
	mkfifo "$fifo"
	echo "$fifo"
	mkdir -p "$(dirname "$1")"
	{ $CMD_GZIP - < "$fifo" > "$1" && rm "$fifo" || kill "$self"; } > /dev/null &
}

guz() {
	fifo="$TMP/$(uuidgen)-$(basename "$1")"
	mkfifo "$fifo"
	echo "$fifo"
	{ zcat "$1" > "$fifo" && rm "$fifo" || kill "$self"; } > /dev/null &
}

have() {
	if [ "$#" -gt 0 -a -e "$1" ]; then
		shift
		have "$@"
	else
		[ "$#" -eq 0 ]
	fi
}

# --------------------------------------------------------------------
# steps

create_taxon_tables() {
	log "Started creating the taxon tables."

	curl --create-dirs --silent --output "$TMP/taxdmp.zip" "$TAXON_URL"
	unzip "$TMP/taxdmp.zip" "names.dmp" "nodes.dmp" -d "$TMP"
	rm "$TMP/taxdmp.zip"

	sed -i'' -e 's/subcohort/no rank/' -e 's/cohort/no rank/' \
		-e 's/subsection/no rank/' -e 's/section/no rank/' \
		-e 's/series/no rank/' -e 's/biotype/no rank/' \
		-e 's/serogroup/no rank/' -e 's/morph/no rank/' \
		-e 's/genotype/no rank/' -e 's/subvariety/no rank/' \
		-e 's/pathogroup/no rank/' -e 's/forma specialis/no rank/' \
		-e 's/serotype/no rank/' -e 's/clade/no rank/' \
		-e 's/isolate/no rank/' -e 's/infraclass/no rank/' \
		-e 's/parvorder/no rank/' "$TMP/nodes.dmp"

	mkdir -p "$TABDIR"
	java_ NamesNodes2TaxonsLineages \
		--names "$TMP/names.dmp" --nodes "$TMP/nodes.dmp" \
		--taxons "$(gz "$TABDIR/taxons.tsv.gz")" \
		--lineages "$(gz "$TABDIR/lineages.tsv.gz")"

	rm "$TMP/names.dmp" "$TMP/nodes.dmp"
	log "Finished creating the taxon tables."
}


download_sources() {
	mkfifo "$TMP/sources"
	echo "$SOURCES" > "$TMP/sources" &
	mkdir -p "$INTDIR"
	while read name url; do
		log "Started downloading $name"
		size="$(curl -I "$url" -s | grep -i content-length | tr -cd '[0-9]')"
		curl --continue-at - --create-dirs "$url" --silent | pv -s "$size" --numeric --timer > "$INTDIR/$name.tsv.gz"
		log "Finished downloading $name"
	done < "$TMP/sources"
	rm "$TMP/sources"
}


create_most_tables() {
	have "$TABDIR/taxons.tsv.gz" || return
	log "Started calculation of most tables."

	sources=""
	mkfifo "$TMP/sources"
	echo "$SOURCES" > "$TMP/sources" &
	while read name url; do
		sources="$sources $name=$(guz "$INTDIR/$name.tsv.gz")"
	done < "$TMP/sources"
	rm "$TMP/sources"

	mkdir -p "$TABDIR" "$INTDIR"
	java_ TaxonsUniprots2Tables \
		--peptide-min "$PEPTIDE_MIN_LENGTH" \
		--peptide-max "$PEPTIDE_MAX_LENGTH" \
		--taxons "$(guz "$TABDIR/taxons.tsv.gz")" \
		--peptides "$(gz "$INTDIR/peptides.tsv.gz")" \
		--uniprot-entries "$(gz "$TABDIR/uniprot_entries.tsv.gz")" \
		--refseq "$(gz "$TABDIR/refseq_cross_references.tsv.gz")" \
		--ec "$(gz "$TABDIR/ec_cross_references.tsv.gz")" \
		--embl "$(gz "$TABDIR/embl_cross_references.tsv.gz")" \
		--go "$(gz "$TABDIR/go_cross_references.tsv.gz")" \
		--interpro "$(gz "$TABDIR/interpro_cross_references.tsv.gz")" \
		--proteomes "$(gz "$INTDIR/proteomes.tsv.gz")" \
		--proteomes-ref "$(gz "$TMP/proteome_cross_references.tsv.gz")" \
		$sources

	mkfifo "$TMP/sources"
	echo "$SOURCES" > "$TMP/sources" &
	while read name url; do
		rm "$INTDIR/$name.tsv.gz"
	done < "$TMP/sources"
	rm "$TMP/sources"

	log "Finished calculation of most tables."
}


join_equalized_pepts_and_entries() {
	have "$INTDIR/peptides.tsv.gz" "$TABDIR/uniprot_entries.tsv.gz" || return
	log "Started the joining of equalized peptides and uniprot entries."
	mkfifo "$TMP/peptides" "$TMP/entries"
	zcat "$INTDIR/peptides.tsv.gz" | awk '{ printf("%012d\t%s\n", $4, $2) }' > "$TMP/peptides" &
	zcat "$TABDIR/uniprot_entries.tsv.gz" | awk '{ printf("%012d\t%s\n", $1, $4) }' > "$TMP/entries" &
	join -t '	' -o '1.2,2.2' -j 1 "$TMP/peptides" "$TMP/entries" \
		| LC_ALL=C $CMD_SORT -k1 \
		| $CMD_GZIP - > "$INTDIR/aa_sequence_taxon_equalized.tsv.gz"
	rm "$TMP/peptides" "$TMP/entries"
	log "Finished the joining of equalized peptides and uniprot entries."
}


join_original_pepts_and_entries() {
	have "$INTDIR/peptides.tsv.gz" "$TABDIR/uniprot_entries.tsv.gz" || return
	log "Started the joining of original peptides and uniprot entries."
	mkfifo "$TMP/peptides" "$TMP/entries"
	zcat "$INTDIR/peptides.tsv.gz" | awk '{ printf("%012d\t%s\n", $4, $3) }' > "$TMP/peptides" &
	zcat "$TABDIR/uniprot_entries.tsv.gz" | awk '{ printf("%012d\t%s\n", $1, $4) }' > "$TMP/entries" &
	join -t '	' -o '1.2,2.2' -j 1 "$TMP/peptides" "$TMP/entries" \
		| LC_ALL=C $CMD_SORT -k1 \
		| $CMD_GZIP - > "$INTDIR/aa_sequence_taxon_original.tsv.gz"
	rm "$TMP/peptides" "$TMP/entries"
	log "Finished the joining of original peptides and uniprot entries."
}


number_sequences() {
	have "$INTDIR/aa_sequence_taxon_equalized.tsv.gz" "$INTDIR/aa_sequence_taxon_original.tsv.gz" || return
	log "Started the numbering of sequences."
	mkfifo "$TMP/equalized" "$TMP/original"
	zcat "$INTDIR/aa_sequence_taxon_equalized.tsv.gz" | cut -f1 | uniq > "$TMP/equalized" &
	zcat "$INTDIR/aa_sequence_taxon_original.tsv.gz" | cut -f1 | uniq > "$TMP/original" &
	LC_ALL=C $CMD_SORT -m "$TMP/equalized" "$TMP/original" | uniq | cat -n \
		| sed 's/^ *//' | $CMD_GZIP - > "$INTDIR/sequences.tsv.gz"
	rm "$TMP/equalized" "$TMP/original"
	log "Finished the numbering of sequences."
}


calculate_equalized_lcas() {
	have "$INTDIR/sequences.tsv.gz" "$INTDIR/aa_sequence_taxon_equalized.tsv.gz" "$TABDIR/lineages.tsv.gz" || return
	log "Started the calculation of equalized LCA's (after substituting AA's by ID's)."
	join -t '	' -o '1.1,2.2' -1 2 -2 1 \
			"$(guz "$INTDIR/sequences.tsv.gz")" \
			"$(guz "$INTDIR/aa_sequence_taxon_equalized.tsv.gz")" \
		| java_ LineagesSequencesTaxons2LCAs "$(guz "$TABDIR/lineages.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/LCAs_equalized.tsv.gz"
	log "Finished the calculation of equalized LCA's (after substituting AA's by ID's)."
}


calculate_original_lcas() {
	have "$INTDIR/sequences.tsv.gz" "$INTDIR/aa_sequence_taxon_original.tsv.gz" "$TABDIR/lineages.tsv.gz" || return
	log "Started the calculation of original LCA's (after substituting AA's by ID's)."
	join -t '	' -o '1.1,2.2' -1 2 -2 1 \
			"$(guz "$INTDIR/sequences.tsv.gz")" \
			"$(guz "$INTDIR/aa_sequence_taxon_original.tsv.gz")" \
		| java_ LineagesSequencesTaxons2LCAs "$(guz "$TABDIR/lineages.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/LCAs_original.tsv.gz"
	log "Finished the calculation of original LCA's (after substituting AA's by ID's)."
}


substitute_equalized_aas() {
	have "$INTDIR/peptides.tsv.gz" "$INTDIR/sequences.tsv.gz" || return
	log "Started the substitution of equalized AA's by ID's for the peptides."
	zcat "$INTDIR/peptides.tsv.gz" \
		| LC_ALL=C $CMD_SORT -k 2b,2 \
		| join -t '	' -o '1.1,2.1,1.3,1.4,1.5' -1 2 -2 2 - "$(guz "$INTDIR/sequences.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/peptides_by_equalized.tsv.gz"
	log "Finished the substitution of equalized AA's by ID's for the peptides."
}


calculate_equalized_fas() {
	have "$INTDIR/peptides_by_equalized.tsv.gz" || return
	log "Started the calculation of equalized FA's."
	mkfifo "$TMP/peptides"
	zcat "$INTDIR/peptides_by_equalized.tsv.gz" | cut -f2,5 > "$TMP/peptides" &
	java_ FunctionAnalysisPeptides "$TMP/peptides" "$(gz "$INTDIR/FAs_equalized.tsv.gz")"
	rm "$TMP/peptides"
	log "Finished the calculation of equalized FA's."
}


substitute_original_aas() {
	have "$INTDIR/peptides_by_equalized.tsv.gz" "$INTDIR/sequences.tsv.gz" || return
	log "Started the substitution of original AA's by ID's for the peptides."
	zcat "$INTDIR/peptides_by_equalized.tsv.gz" \
		| LC_ALL=C $CMD_SORT -k 3b,3 \
		| join -t '	' -o '1.1,1.2,2.1,1.4,1.5' -1 3 -2 2 - "$(guz "$INTDIR/sequences.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/peptides_by_original.tsv.gz"
	log "Finished the substitution of equalized AA's by ID's for the peptides."
}


calculate_original_fas() {
	have "$INTDIR/peptides_by_original.tsv.gz" || return
	log "Started the calculation of original FA's."
	mkfifo "$TMP/peptides"
	zcat "$INTDIR/peptides_by_original.tsv.gz" | cut -f3,5 > "$TMP/peptides" &
	java_ FunctionAnalysisPeptides "$TMP/peptides" "$(gz "$INTDIR/FAs_original.tsv.gz")"
	rm "$TMP/peptides"
	log "Finished the calculation of original FA's."
}


sort_peptides() {
	have "$INTDIR/peptides_by_original.tsv.gz" || return
	log "Started sorting the peptides table."
	mkdir -p "$TABDIR"
	zcat "$INTDIR/peptides_by_original.tsv.gz" \
		| LC_ALL=C $CMD_SORT -n \
		| $CMD_GZIP - > "$TABDIR/peptides.tsv.gz"
	log "Finished sorting the peptides table."
}


create_sequence_table() {
	have "$INTDIR/LCAs_original.tsv.gz" "$INTDIR/LCAs_equalized.tsv.gz" "$INTDIR/FAs_original.tsv.gz" "$INTDIR/FAs_equalized.tsv.gz" "$INTDIR/sequences.tsv.gz" || return
	log "Started the creation of the sequences table."
	mkdir -p "$TABDIR"
	mkfifo "$TMP/olcas" "$TMP/elcas" "$TMP/ofas" "$TMP/efas"
	zcat "$INTDIR/LCAs_original.tsv.gz"  | awk '{ printf("%012d\t%s\n", $1, $2) }' > "$TMP/olcas" &
	zcat "$INTDIR/LCAs_equalized.tsv.gz" | awk '{ printf("%012d\t%s\n", $1, $2) }' > "$TMP/elcas" &
	zcat "$INTDIR/FAs_original.tsv.gz"   | awk '{ printf("%012d\t%s\n", $1, $2) }' > "$TMP/ofas" &
	zcat "$INTDIR/FAs_equalized.tsv.gz"  | awk '{ printf("%012d\t%s\n", $1, $2) }' > "$TMP/efas" &
	zcat "$INTDIR/sequences.tsv.gz"      | awk '{ printf("%012d\t%s\n", $1, $2) }' \
		| join --nocheck-order -a1 -e '\N' -t '	' -o "1.1 1.2 2.2" - "$TMP/olcas" \
		| join --nocheck-order -a1 -e '\N' -t '	' -o "1.1 1.2 1.3 2.2" - "$TMP/elcas" \
		| join --nocheck-order -a1 -e '\N' -t '	' -o '1.1 1.2 1.3 1.4 2.2' - "$TMP/ofas" \
		| join --nocheck-order -a1 -e '\N' -t '	' -o '1.1 1.2 1.3 1.4 1.5 2.2' - "$TMP/efas" \
		| sed 's/^0*//' | $CMD_GZIP - > "$TABDIR/sequences.tsv.gz"
	rm "$TMP/olcas" "$TMP/elcas" "$TMP/ofas" "$TMP/efas"
	log "Finished the creation of the sequences table."
}


fetch_proteomes() {
	have "$INTDIR/proteomes.tsv.gz" || return
	log "Started fetching of proteome data."
	mkfifo "$TMP/data"
	$CMD_SORT -t'	' -k6 "$TMP/data" | $CMD_GZIP - > "$INTDIR/proteomes_data.tsv.gz" & # sort by assembly
	java_ FetchProteomes "$(guz "$INTDIR/proteomes.tsv.gz")" "$TMP/data"
	rm "$TMP/data"
	log "Finished fetching of proteome data."
}


fetch_type_strains() {
	log "Started fetching of type strain data."
	mkdir -p "$INTDIR"
	touch "$TMP/type_strains"
	header="$(curl -s -d 'db=assembly' -d 'term="sequence from type"' -d 'field=filter' -d 'usehistory=y' "$ENTREZ_URL/esearch.fcgi" \
	        | grep -e 'QueryKey' -e 'WebEnv' | tr -d '\n')"
	query_key="$(echo "$header" | sed -n 's/.*<QueryKey>\(.*\)<\/QueryKey>.*/\1/p')"
	web_env="$(echo "$header" | sed -n 's/.*<WebEnv>\(.*\)<\/WebEnv>.*/\1/p')"

	returned="$ENTREZ_BATCH_SIZE"
	retstart='1'
	while [ "$returned" = "$ENTREZ_BATCH_SIZE" ]; do
		returned="$(curl -d 'db=assembly' \
		                 -d "query_key=$query_key" \
		                 -d "WebEnv=$web_env" \
		                 -d "retmax=$ENTREZ_BATCH_SIZE" \
		                 -d "retstart=$retstart" \
		                 -s "$ENTREZ_URL/esummary.fcgi" \
		          | grep '<Genbank>' \
		          | sed -e 's/<[^>]*>//g' -e 's/[ \t][ \t]*//g' \
		          | tee -a "$TMP/type_strains" \
		          | wc -l)"
		 retstart="$(( retstart + returned ))"
	done

	$CMD_SORT "$TMP/type_strains" | sed 's/$/\t1/' | $CMD_GZIP - > "$INTDIR/proteomes_type_strains.tsv.gz"
	log "Finished fetching of type strain data."
}


join_type_strains_to_proteomes() {
	have "$INTDIR/proteomes_data.tsv.gz" "$INTDIR/proteomes_type_strains.tsv.gz" || return
	log "Started adding type strain boolean to proteome data."
	mkdir -p "$TABDIR"
	# tmp: 1)id 2)accession-id 3)name-str 4)reference-bool 5)strain-id 6)assembly-id
	# strain: assembly-id
	# join: 1)assembly-id 2)id 3)accession-id 4)name-str 5)reference-int 6)strain-id 7)strain-int
	# awk: id accession-id name-str TAXON strain-bool reference-bool strain-id assembly-id
	join -1 6 -2 1 -a 1 -e "0" -t '	' -o "1.1 1.2 1.3 2.2 1.5 1.4 1.6 1.7" \
			"$(guz "$INTDIR/proteomes_data.tsv.gz")" \
			"$(guz "$INTDIR/proteomes_type_strains.tsv.gz")" \
		| awk 'function b(a){if (a == 1)return "\x01"; return "\x00"} \
		       BEGIN { FS = OFS = "\t" }{ print $1,$2,$3,"\\N",b($4),b($5),$6,$7,$8 }' \
		| $CMD_SORT -n \
		| $CMD_GZIP - > "$TABDIR/proteomes.tsv.gz"
	log "Finished adding type strain boolean to proteome data."
}


fetch_ec_numbers() {
	log "Started creating EC numbers."
	mkdir -p "$TABDIR"
	{
		curl -s "$EC_CLASS_URL" | grep '^[1-9]' | sed 's/\. *\([-0-9]\)/.\1/g' | sed 's/  */\t/' | sed 's/\.*$//'
		curl -s "$EC_NUMBER_URL" | grep -E '^ID|^DE' | awk '
			BEGIN { FS="   "
			        OFS="\t" }
			/^ID/ { if(id != "") { print id, name }
			        name = ""
			        id = $2 }
			/^DE/ { gsub(/.$/, "", $2)
			        name = name $2 }
			END   { print id, name }'
	} | cat -n | sed 's/^ *//' | $CMD_GZIP - > "$TABDIR/ec_numbers.tsv.gz"
	log "Finished creating EC numbers."
}


fetch_go_terms() {
	log "Started creating GO terms."
	mkdir -p "$TABDIR"
	curl -Ls "$GO_TERM_URL" | awk '
		BEGIN { OFS = "	"; id = 1 }
		/^\[.*\]$/ { # start of a record
			type = $0
			alt_ctr = 0
			split("", record, ":")
			split("", ids, ":")
			next }
		/^(alt_id|id).*$/ { # a id or alt_id field in a record
			value = $0; sub("[^ ]*: ", "", value)
			record["id"][alt_ctr] = value
			alt_ctr++
			next }
		!/^$/ { # a field in a record
			key = $0;   sub(":.*", "", key)
			value = $0; sub("[^ ]*: ", "", value)
			record[key] = value }
		/^$/ { # end of a record
			if (type == "[Term]") {
				sub("_", " ", record["namespace"])
				for(i in record["id"]) {
					print id, record["id"][i], record["namespace"], record["name"]
					id++
				}
			}
			type = "" }' | $CMD_GZIP - > "$TABDIR/go_terms.tsv.gz"
	log "Finished creating GO terms."
}


fetch_interpro_entries() {
	log "Started creating InterPro Entries."
	mkdir -p "$TABDIR"
	curl -s "$INTERPRO_URL" | grep '^IPR' | cat -n | sed 's/^ *//' | $CMD_GZIP - > "$TABDIR/interpro_entries.tsv.gz"
	log "Finished creating InterPro Entries."
}


create_kmer_index() {
	have "$TABDIR/uniprot_entries.tsv.gz" "$TABDIR/taxons.tsv.gz" || return
	log "Started the construction of the $KMER_LENGTH-mer index."
	for PREFIX in A C D E F G H I K L M N P Q R S T V W Y; do
		pv -N $PREFIX "$TABDIR/uniprot_entries.tsv.gz" \
			| gunzip \
			| cut -f4,7 \
			| grep "^[0-9]*	[ACDEFGHIKLMNPQRSTVWY]*$" \
			| tee -a failure \
			| umgap splitkmers -k"$KMER_LENGTH" \
			| sed -n "s/^$PREFIX//p" \
			| LC_ALL=C $CMD_SORT \
			| sed "s/^/$PREFIX/"
	done \
			| umgap joinkmers "$(guz "$TABDIR/taxons.tsv.gz")" \
			| cut -d'	' -f1,2 \
			| umgap buildindex \
			> "$TABDIR/$KMER_LENGTH-mer.index"
	log "Finished the construction of the $KMER_LENGTH-mer index."
}

# --------------------------------------------------------------------
# targets

checkdep curl
checkdep java
checkdep mvn "Maven"
checkdep uuidgen

case "$1" in
database)
	checkdep pv

	create_taxon_tables
	download_sources
	create_most_tables
	join_equalized_pepts_and_entries
	join_original_pepts_and_entries
	number_sequences
	calculate_equalized_lcas
	rm "$INTDIR/aa_sequence_taxon_equalized.tsv.gz"
	calculate_original_lcas
	rm "$INTDIR/aa_sequence_taxon_original.tsv.gz"
	substitute_equalized_aas
	rm "$INTDIR/peptides.tsv.gz"
	calculate_equalized_fas
	substitute_original_aas
	rm "$INTDIR/peptides_by_equalized.tsv.gz"
	calculate_original_fas
	sort_peptides
	rm "$INTDIR/peptides_by_original.tsv.gz"
	create_sequence_table
	rm "$INTDIR/LCAs_original.tsv.gz"
	rm "$INTDIR/LCAs_equalized.tsv.gz"
	rm "$INTDIR/FAs_original.tsv.gz"
	rm "$INTDIR/FAs_equalized.tsv.gz"
	rm "$INTDIR/sequences.tsv.gz"
	fetch_proteomes
	rm "$INTDIR/proteomes.tsv.gz"
	fetch_type_strains
	join_type_strains_to_proteomes
	fetch_ec_numbers
	fetch_go_terms
	fetch_interpro_entries
	;;
static-database)
	if ! have "$TABDIR/taxons.tsv.gz"; then
		create_taxon_tables
	fi
	fetch_ec_numbers
	fetch_go_terms
	fetch_interpro_entries
	;;
index)
	checkdep pv
	checkdep umgap "umgap crate (for umgap buildindex)"

	if ! have "$TABDIR/taxons.tsv.gz"; then
		create_taxon_tables
	fi
	if ! have "$TABDIR/uniprot_entries.tsv.gz"; then
		download_sources
		create_most_tables
	fi
	create_kmer_index
	;;
esac
