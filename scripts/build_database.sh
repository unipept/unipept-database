#! /usr/bin/env bash

set -eo pipefail

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

self="$$"

UNIPEPT_TEMP_CONSTANT="unipept_temp"

# Default values for the optional parameters to this script.
TEMP_DIR="/tmp"
INDEX_DIR="/tmp/unipept_index"
TAXA="1"
VERBOSE="false"
SORT_MEMORY="2g"

OLD_TMPDIR="$TMPDIR"

printHelp() {
	cat << END
Usage: $(basename "$0") [OPTIONS] BUILD_TYPE DB_NAMES DB_SOURCES OUTPUT_DIR
Build Unipept database from a specific collection of UniProt resources.

Required parameters:
  * BUILD_TYPE: One of database, static-database, kmer-index, tryptic-index.

  * DB_NAMES: List with all names of the different databases that should be parsed. Every name in this list
  corresponds with the respective database source given for the DB_SOURCES parameter. The items in this list should be
  delimited by comma's.

  * DB_SOURCES: List of UniProt source URLs. The items in this list should be delimited by comma's. Commonly used
  databases and their corresponding sources are:
    - swissprot: https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.xml.gz
    - trembl: https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_trembl.xml.gz

  * OUTPUT_DIR: Directory in which the tsv.gz-files that are produced by this script will be stored.

Options:
  * -h
  Display help for this script.

  * -v
  Enable verbose mode. Print more detailed information about what's going on under the hood to stderr.

  * -f [TAXA_IDS]
  Filter by taxa. List of taxa for which all corresponding UniProt entries should be retained. First, for each of the
  taxa from the given list, we look up all of the direct and indirect child nodes in the NCBI taxonomy tree. Then, all
  UniProt-entries from the database sources are filtered in such a way that only entries that are associated with one
  of the taxa (or it's children) provided here are retained. These items must be delimited by comma's. If 1 is passed,
  no filtering will be performed (since 1 corresponds to the NCBI ID of the root node).

  * -i [INDEX_DIR]
  Specify the directory in which the Unipept lookup index files will be stored. This index will be automatically built
  the first time this script is executed and is being used to speed up computations. If, in the future, this script is
  used again, the index can be reused to compute the database tables faster. If the given directory does not exist,
  it will be created by this script.

  * -d [TEMP_DIR]
  Specify the temporary directory that can be used by this script to temporary store files that are required to build
  the requested Unipept tables. If the given directory does not exist, it will be created by this script.

  * -m [MAX_SORTING_MEMORY_PER_THREAD]
  Specify how much memory the sorting processes are allowed to use. This parameter needs to be formatted according to
  the specifications required by the linux sort command (for example: 2G for 2 gigabytes). Note that two sorting
  processes will be executed in parallel, so keep that in mind when setting this parameter. The default value is 2G.

Dependencies:
  This script requires some non-standard dependencies to be installed before it can be used. This is a list of these
  items (which can normally be installed through your package manager):

  * maven
  * node-js
  * curl
  * pv
  * pigz
  * java
  * uuidgen
  * parallel
END
}

# This function removes all temporary files that have been created by this script.
clean() {
	# Clean contents of temporary directory
	rm -rf "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT"
	export TMPDIR="$OLD_TMPDIR"
}

# Stop the script and remove all temporary files that are created by this script.
terminateAndExit() {
	echo "Error: execution of the script was cancelled by the user." 1>&2
	echo ""
	clean
	exit 1
}

# Can be called when an error has occurred during the execution of the script. This function will inform the user that
# an error has occurred and will properly exit the script.
errorAndExit() {
	echo "Error: the script experienced an error while trying to build the requested database." 1>&2
	echo "" 1>&2
	clean
	exit 2
}

###
# Informs the user that the syntaxis provided for this script is incorrect and exits with status code 3.
#
# Parameters:
#	N/A
#
# Returns:
#	N/A
###
printUnknownOptionAndExit() {
	echo "Error: unknown invocation of script. Consult the information below for more details on how to use this script."
	echo "" 1>&2
	printHelp
	exit 3
}

###
# Checks if the given specified location is a valid directory. If the given path points to a non-existing item, a new
# directory will be created at this location. The script will exit with status code 4 if an invalid path is presented.
#
# Parameters:
#	* path: should point to the location that needs to be checked (or created if it does not exist).
#
# Returns:
# 	N/A
###
checkDirectoryAndCreate() {
	if [[ ! -e "$1" ]]
	then
		mkdir -p "$1"
	fi

	if [[ ! -d "$1" ]]
	then
		echo "The path you provided is invalid: $1. Please provide a valid path and try again." 1>&2
		exit 4
	fi
}

###
# Checks if a specific dependency is met on this system. If not, an error message is provided that indicates to the user
# that this dependency should be installed. The script is exited with code 6 if the dependency is not met.
#
# Parameters:
#	* installed package name: name of the dependency (name for dependency that should be recognized by the operating
#   * system).
#   * display name: optional, nice name of the dependency (name that should be useful for the user).
#
# Returns:
#	N/A
###
checkdep() {
    which $1 > /dev/null 2>&1 || hash $1 > /dev/null 2>&1 || {
        echo "Unipept database builder requires ${2:-$1} to be installed." >&2
        exit 6
    }
}

log() { echo "$(date +'[%s (%F %T)]')" "$@"; }

trap terminateAndExit SIGINT
trap errorAndExit ERR
trap clean EXIT

### Start of the database construction script itself.

### Process all options for this script and make sure that everything is alright.

while getopts ":hvm:f:i:d:" opt
do
	case $opt in
		h)
			printHelp
			exit 0
			;;
		f)
			TAXA="$OPTARG"
			if [[ ! "$TAXA" =~ ^([0-9]*,?)*$ ]]
			then
				echo -n "Error: invalid format encountered for the provided taxa filter. Only valid NCBI ID's, " 1>&2
				echo "delimited by comma's are allowed." 1>&2
				exit 5
			fi
			;;
		i)
			checkDirectoryAndCreate "$OPTARG"
			INDEX_DIR="$OPTARG"
			;;
		d)
			checkDirectoryAndCreate "$OPTARG/$UNIPEPT_TEMP_CONSTANT"
			TEMP_DIR="$OPTARG"
			;;
	  m)
	    SORT_MEMORY="$OPTARG"
	    ;;
	  v)
	    VERBOSE="true"
	    ;;
	  \? )
	    printUsageAndExit
	    ;;
	esac
done

shift $((OPTIND - 1))

if [ "$VERBOSE" = "true" ]
then
  echo "INFO VERBOSE: Verbose mode enabled. Printing debug information." 1>&2
fi

# Now, we need to check if 4 positional arguments are provided to this script by the user.
if [[ "$#" -ne 4 ]]
then
	printUnknownOptionAndExit
fi

# This is required for the sort command to use the correct temp directory
export TMPDIR="$TEMP_DIR"

BUILD_TYPE="$1"

OLDIFS="$IFS"
IFS=","

DB_TYPES=$( (echo "$2") )
DB_SOURCES=$( (echo "$3") )

IFS="$OLDIFS"

OUTPUT_DIR="$4"

checkDirectoryAndCreate "$4"

### All options passed to the script are verified and should be valid at this point. Now continue with the actual
### database construction process itself.

### Check that all dependencies required for this script to function are met.
checkdep curl
checkdep java
checkdep mvn "Maven"
checkdep uuidgen
checkdep pv
checkdep node
checkdep pigz

### Default configuration for this script
PEPTIDE_MIN_LENGTH=5 # What is the minimum length (inclusive) for tryptic peptides?"
PEPTIDE_MAX_LENGTH=50 # What is the maximum length (inclusive) for tryptic peptides?"
TABDIR="$OUTPUT_DIR" # Where should I store the final TSV files (large, single-write)?
INTDIR="$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT" # Where should I store intermediate TSV files (large, single-write, multiple-read?
KMER_LENGTH=9 # What is the length (k) of the K-mer peptides?
JAVA_MEM="2g" # How much memory should Java use?
CMD_SORT="sort --buffer-size=$SORT_MEMORY --parallel=4" # Which sort command should I use?
CMD_GZIP="gzip -" # Which pipe compression command should I use?
ENTREZ_BATCH_SIZE=1000 # Which batch size should I use for communication with Entrez?

TAXON_URL="https://ftp.ncbi.nih.gov/pub/taxonomy/taxdmp.zip"
EC_CLASS_URL="https://ftp.expasy.org/databases/enzyme/enzclass.txt"
EC_NUMBER_URL="https://ftp.expasy.org/databases/enzyme/enzyme.dat"
GO_TERM_URL="http://geneontology.org/ontology/go-basic.obo"
INTERPRO_URL="http://ftp.ebi.ac.uk/pub/databases/interpro/current_release/entry.list"

### Utility functions required for the database construction process.

reportProgress() {
  # Name of the current building step in the progress of making the custom database
  STEP="$2"
  STEP_IDX="$3"

  # Value between 0 and 100 (-1 for indeterminate progress)
  if [[ "$1" == "-" ]]
  then
    while read -r PROGRESS
    do
      echo "PROGRESS <-> $STEP <-> $PROGRESS <-> $STEP_IDX"
    done
  else
    PROGRESS="$1"
    echo "PROGRESS <-> $STEP <-> $PROGRESS <-> $STEP_IDX"
  fi
}

gz() {
	fifo="$(uuidgen)-$(basename "$1")"
	mkfifo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	echo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	mkdir -p "$(dirname "$1")"
	{ $CMD_GZIP - < "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" > "$1" && rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" || kill "$self"; } > /dev/null &
}

guz() {
	fifo="$(uuidgen)-$(basename "$1")"
	mkfifo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	echo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	{ zcat "$1" > "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" && rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" || kill "$self"; } > /dev/null &
}

have() {
	if [ "$#" -gt 0 -a -e "$1" ]; then
		shift
		have "$@"
	else
		[ "$#" -eq 0 ]
	fi
}

### All the different database construction steps.

create_taxon_tables() {
	log "Started creating the taxon tables."
	reportProgress -1 "Creating taxon tables." 1

	curl --create-dirs --silent --output "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/taxdmp.zip" "$TAXON_URL"
	unzip "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/taxdmp.zip" "names.dmp" "nodes.dmp" -d "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT"
	rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/taxdmp.zip"

	sed -i'' -e 's/subcohort/no rank/' -e 's/cohort/no rank/' \
		-e 's/subsection/no rank/' -e 's/section/no rank/' \
		-e 's/series/no rank/' -e 's/biotype/no rank/' \
		-e 's/serogroup/no rank/' -e 's/morph/no rank/' \
		-e 's/genotype/no rank/' -e 's/subvariety/no rank/' \
		-e 's/pathogroup/no rank/' -e 's/forma specialis/no rank/' \
		-e 's/serotype/no rank/' -e 's/clade/no rank/' \
		-e 's/isolate/no rank/' -e 's/infraclass/no rank/' \
		-e 's/parvorder/no rank/' "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/nodes.dmp"

	mkdir -p "$OUTPUT_DIR"
	java -Xms"$JAVA_MEM" -Xmx"$JAVA_MEM" -jar "$CURRENT_LOCATION/helper_scripts/NamesNodes2TaxonsLineages.jar" \
		--names "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/names.dmp" --nodes "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/nodes.dmp" \
		--taxons "$(gz "$OUTPUT_DIR/taxons.tsv.gz")" \
		--lineages "$(gz "$OUTPUT_DIR/lineages.tsv.gz")"

	rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/names.dmp" "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/nodes.dmp"
	log "Finished creating the taxon tables."
}

download_and_convert_all_sources() {
  IDX=0

  OLDIFS="$IFS"
  IFS=","

  DB_TYPES_ARRAY=($DB_TYPES)
  DB_SOURCES_ARRAY=($DB_SOURCES)

  IFS="$OLDIFS"

  while [[ "$IDX" -ne "${#DB_TYPES_ARRAY}" ]] && [[ -n $(echo "${DB_TYPES_ARRAY[$IDX]}" | sed "s/\s//g") ]]
  do
    DB_TYPE=${DB_TYPES_ARRAY[$IDX]}
    DB_SOURCE=${DB_SOURCES_ARRAY[$IDX]}

    echo "Producing index for $DB_TYPE."

    # Where should we store the index of this converted database.
    DB_INDEX_OUTPUT="$INDEX_DIR/$DB_TYPE"

    echo "$DB_INDEX_OUTPUT"

    mkdir -p "$DB_INDEX_OUTPUT"

    # No ETags or other header requests are available if a database is requested from the UniProt REST API. That's why
    # we always need to reprocess the database in that case.
    if [[ $DB_SOURCE =~ "rest" ]]
    then
      echo "Index for $DB_TYPE is requested over UniProt REST API and needs to be recreated."

      # Remove old database version and continue building the new database.
      rm -rf "$DB_INDEX_OUTPUT"
      mkdir -p "$DB_INDEX_OUTPUT"

      reportProgress -1 "Downloading database index for $DB_TYPE." 3

      # Curl doesn't allow downloading in a specific directory without a filename,
      # do this as a temporary workaround: cd to the directory, curl, and cd back
      # TODO use wget instead? will discuss later
      # TODO resumability
#      XML_FILE=$(cd "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT" && curl "$DB_SOURCE" --silent -O --remote-name -w "%{filename_effective}")
#      zcat "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$XML_FILE" | "$CURRENT_LOCATION/helper_scripts/xml-parser" -t "$DB_TYPE" --threads 0 --verbose "$VERBOSE" | node "$CURRENT_LOCATION/helper_scripts/WriteToChunk.js" "$DB_INDEX_OUTPUT" "$VERBOSE"
      zcat "/uniprot_sprot.xml.gz" | java -jar "$CURRENT_LOCATION/helper_scripts/XmlToTabConverter.jar" 5 50 "$DB_TYPE" false | node "$CURRENT_LOCATION/helper_scripts/WriteToChunk.js" "$DB_INDEX_OUTPUT" "$VERBOSE"
      rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$XML_FILE"

      # Now, compress the different chunks
      CHUNKS=$(find "$DB_INDEX_OUTPUT" -name "*.chunk")
      TOTAL_CHUNKS=$(echo "$CHUNKS" | wc -l)

      CHUNK_IDX=1

      for CHUNK in $CHUNKS
      do
        echo "Compressing $CHUNK_IDX of $TOTAL_CHUNKS for $DB_TYPE"
        pv -i 5 -n "$CHUNK" 2> >(reportProgress - "Processing chunk $CHUNK_IDX of $TOTAL_CHUNKS for $DB_TYPE index." 4 >&2) | pigz > "$CHUNK.gz"
        # Remove the chunk that was just compressed
        rm "$CHUNK"
        CHUNK_IDX=$((CHUNK_IDX + 1))
      done

      echo "Index for $DB_TYPE has been produced."
    else

      # Check for this database if the database index is already present
      CURRENT_ETAG=$(curl --head --silent "$DB_SOURCE" | grep "ETag" | cut -d " " -f2 | tr -d "\"")

      if [[ ! -e "$DB_INDEX_OUTPUT/metadata" ]]
      then
        touch "$DB_INDEX_OUTPUT/metadata"
      fi

      PREVIOUS_ETAG=$([[ -r "$DB_INDEX_OUTPUT/metadata" ]] && cat "$DB_INDEX_OUTPUT/metadata" 2> /dev/null)

      if [[ -n "$CURRENT_ETAG" ]] && [[ "$CURRENT_ETAG" == "$PREVIOUS_ETAG" ]]
      then
        echo "Index for $DB_TYPE is already present and can be reused."
      else
        echo "Index for $DB_TYPE is not yet present and needs to be created."
        # Remove old database version and continue building the new database.
        rm -rf "$DB_INDEX_OUTPUT"
        mkdir -p "$DB_INDEX_OUTPUT"
        touch "$DB_INDEX_OUTPUT/metadata"

        reportProgress 0 "Building database index for $DB_TYPE." 2

        SIZE="$(curl -I "$DB_SOURCE" -s | grep -i content-length | tr -cd '[0-9]')"

        zcat "/uniprot_sprot.xml.gz" | java -jar "$CURRENT_LOCATION/helper_scripts/XmlToTabConverter.jar" 5 50 "$DB_TYPE" false | node "$CURRENT_LOCATION/helper_scripts/WriteToChunk.js" "$DB_INDEX_OUTPUT" "$VERBOSE"

        # Now, compress the different chunks
        CHUNKS=$(find "$DB_INDEX_OUTPUT" -name "*.chunk")
        TOTAL_CHUNKS=$(echo "$CHUNKS" | wc -l)

        CHUNK_IDX=1

        for CHUNK in $CHUNKS
        do
          echo "Compressing $CHUNK_IDX of $TOTAL_CHUNKS for $DB_TYPE"
          pv -i 5 -n "$CHUNK" 2> >(reportProgress - "Processing chunk $CHUNK_IDX of $TOTAL_CHUNKS for $DB_TYPE index." 4 >&2) | pigz > "$CHUNK.gz"
          # Remove the chunk that was just compressed
          rm "$CHUNK"
          CHUNK_IDX=$((CHUNK_IDX + 1))
        done

        echo "$CURRENT_ETAG" > "$DB_INDEX_OUTPUT/metadata"

        echo "Index for $DB_TYPE has been produced."
      fi
    fi

    IDX=$((IDX + 1))
  done
}

filter_sources_by_taxa() {
  IDX=0

  OLDIFS="$IFS"
  IFS=","

  DB_TYPES_ARRAY=($DB_TYPES)
  DB_SOURCES_ARRAY=($DB_SOURCES)

  IFS="$OLDIFS"

  # First echo the header that's supposed to be part of all files.
  FIRST_DB_TYPE=${DB_TYPES_ARRAY[0]}
  cat "$INDEX_DIR/$FIRST_DB_TYPE/db.header"

  while [[ "$IDX" -ne "${#DB_TYPES_ARRAY}" ]] && [[ -n $(echo "${DB_TYPES_ARRAY[$IDX]}" | sed "s/\s//g") ]]
  do
    DB_TYPE=${DB_TYPES_ARRAY[$IDX]}
    DB_SOURCE=${DB_SOURCES_ARRAY[$IDX]}

    DB_INDEX_OUTPUT="$INDEX_DIR/$DB_TYPE"

    mkdir -p "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/filter"

    $CURRENT_LOCATION/helper_scripts/filter_taxa.sh "$TAXA" "$DB_INDEX_OUTPUT" "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/filter" "$OUTPUT_DIR/lineages.tsv.gz"

    IDX=$((IDX + 1))
  done
}

create_most_tables() {
	have "$OUTPUT_DIR/taxons.tsv.gz" || return
	log "Started calculation of most tables."

  reportProgress "-1" "Started building main database tables." 5

	mkdir -p "$OUTPUT_DIR" "$INTDIR"

	if [ $VERBOSE = "true" ]
	then
	  $VERBOSE_FLAG="--verbose"
  fi

	cat - | java -Xms"$JAVA_MEM" -Xmx"$JAVA_MEM" -jar "$CURRENT_LOCATION/helper_scripts/TaxonsUniprots2Tables.jar" \
		--peptide-min "$PEPTIDE_MIN_LENGTH" \
		--peptide-max "$PEPTIDE_MAX_LENGTH" \
		--taxons "$(guz "$OUTPUT_DIR/taxons.tsv.gz")" \
		--peptides "$(gz "$INTDIR/peptides.tsv.gz")" \
		--uniprot-entries "$(gz "$OUTPUT_DIR/uniprot_entries.tsv.gz")" \
		--ec "$(gz "$OUTPUT_DIR/ec_cross_references.tsv.gz")" \
		--go "$(gz "$OUTPUT_DIR/go_cross_references.tsv.gz")" \
		--interpro "$(gz "$OUTPUT_DIR/interpro_cross_references.tsv.gz")" \
		$VERBOSE_FLAG

	log "Finished calculation of most tables with status $?"
}

create_tables_and_filter() {
  filter_sources_by_taxa | create_most_tables
}

join_equalized_pepts_and_entries() {
  echo "Test if files for joining peptides are available."
	have "$INTDIR/peptides.tsv.gz" "$OUTPUT_DIR/uniprot_entries.tsv.gz" || return
	log "Started the joining of equalized peptides and uniprot entries."
	mkfifo "peptides_eq" "entries_eq"
	zcat "$INTDIR/peptides.tsv.gz" | gawk '{ printf("%012d\t%s\n", $4, $2) }' > "peptides_eq" &
	zcat "$OUTPUT_DIR/uniprot_entries.tsv.gz" | gawk '{ printf("%012d\t%s\n", $1, $4) }' > "entries_eq" &
	join -t '	' -o '1.2,2.2' -j 1 "peptides_eq" "entries_eq" \
		| LC_ALL=C $CMD_SORT -k1 \
		| $CMD_GZIP - > "$INTDIR/aa_sequence_taxon_equalized.tsv.gz"
	rm "peptides_eq" "entries_eq"
	log "Finished the joining of equalized peptides and uniprot entries with status $?."
}


join_original_pepts_and_entries() {
	have "$INTDIR/peptides.tsv.gz" "$OUTPUT_DIR/uniprot_entries.tsv.gz" || return
	log "Started the joining of original peptides and uniprot entries."
	mkfifo "peptides_orig" "entries_orig"
	zcat "$INTDIR/peptides.tsv.gz" | gawk '{ printf("%012d\t%s\n", $4, $3) }' > "peptides_orig" &
	zcat "$OUTPUT_DIR/uniprot_entries.tsv.gz" | gawk '{ printf("%012d\t%s\n", $1, $4) }' > "entries_orig" &
	join -t '	' -o '1.2,2.2' -j 1 "peptides_orig" "entries_orig" \
		| LC_ALL=C $CMD_SORT -k1 \
		| $CMD_GZIP - > "$INTDIR/aa_sequence_taxon_original.tsv.gz"
	rm "peptides_orig" "entries_orig"
	log "Finished the joining of original peptides and uniprot entries with status $?."
}


number_sequences() {
	have "$INTDIR/aa_sequence_taxon_equalized.tsv.gz" "$INTDIR/aa_sequence_taxon_original.tsv.gz" || return
	log "Started the numbering of sequences."
	mkfifo "equalized" "original"
	zcat "$INTDIR/aa_sequence_taxon_equalized.tsv.gz" | cut -f1 | uniq > "equalized" &
	zcat "$INTDIR/aa_sequence_taxon_original.tsv.gz" | cut -f1 | uniq > "original" &
	LC_ALL=C $CMD_SORT -m "equalized" "original" | uniq | cat -n \
		| sed 's/^ *//' | $CMD_GZIP - > "$INTDIR/sequences.tsv.gz"
	rm "equalized" "original"
	log "Finished the numbering of sequences with status $?."
}


calculate_equalized_lcas() {
	have "$INTDIR/sequences.tsv.gz" "$INTDIR/aa_sequence_taxon_equalized.tsv.gz" "$OUTPUT_DIR/lineages.tsv.gz" || return
	log "Started the calculation of equalized LCA's (after substituting AA's by ID's)."
	join -t '	' -o '1.1,2.2' -1 2 -2 1 \
			"$(guz "$INTDIR/sequences.tsv.gz")" \
			"$(guz "$INTDIR/aa_sequence_taxon_equalized.tsv.gz")" \
		| java -Xms"$JAVA_MEM" -Xmx"$JAVA_MEM" -jar "$CURRENT_LOCATION/helper_scripts/LineagesSequencesTaxons2LCAs.jar" "$(guz "$OUTPUT_DIR/lineages.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/LCAs_equalized.tsv.gz"
	log "Finished the calculation of equalized LCA's (after substituting AA's by ID's) with status $?."
}


calculate_original_lcas() {
	have "$INTDIR/sequences.tsv.gz" "$INTDIR/aa_sequence_taxon_original.tsv.gz" "$OUTPUT_DIR/lineages.tsv.gz" || return
	log "Started the calculation of original LCA's (after substituting AA's by ID's)."
	join -t '	' -o '1.1,2.2' -1 2 -2 1 \
			"$(guz "$INTDIR/sequences.tsv.gz")" \
			"$(guz "$INTDIR/aa_sequence_taxon_original.tsv.gz")" \
		| java -Xms"$JAVA_MEM" -Xmx"$JAVA_MEM" -jar "$CURRENT_LOCATION/helper_scripts/LineagesSequencesTaxons2LCAs.jar" "$(guz "$OUTPUT_DIR/lineages.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/LCAs_original.tsv.gz"
	log "Finished the calculation of original LCA's (after substituting AA's by ID's) with status $?."
}


substitute_equalized_aas() {
	have "$INTDIR/peptides.tsv.gz" "$INTDIR/sequences.tsv.gz" || return
	log "Started the substitution of equalized AA's by ID's for the peptides."
	zcat "$INTDIR/peptides.tsv.gz" \
		| LC_ALL=C $CMD_SORT -k 2b,2 \
		| join -t '	' -o '1.1,2.1,1.3,1.4,1.5' -1 2 -2 2 - "$(guz "$INTDIR/sequences.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/peptides_by_equalized.tsv.gz"
	log "Finished the substitution of equalized AA's by ID's for the peptides with status $?."
}


calculate_equalized_fas() {
	have "$INTDIR/peptides_by_equalized.tsv.gz" || return
	log "Started the calculation of equalized FA's."
	mkfifo "peptides_eq"
	zcat "$INTDIR/peptides_by_equalized.tsv.gz" | cut -f2,5 > "peptides_eq" &
	node  "$CURRENT_LOCATION/helper_scripts/FunctionalAnalysisPeptides.js" "peptides_eq" "$(gz "$INTDIR/FAs_equalized.tsv.gz")"
	rm "peptides_eq"
	log "Finished the calculation of equalized FA's with status $?."
}


substitute_original_aas() {
	have "$INTDIR/peptides_by_equalized.tsv.gz" "$INTDIR/sequences.tsv.gz" || return
	log "Started the substitution of original AA's by ID's for the peptides."
	zcat "$INTDIR/peptides_by_equalized.tsv.gz" \
		| LC_ALL=C $CMD_SORT -k 3b,3 \
		| join -t '	' -o '1.1,1.2,2.1,1.4,1.5' -1 3 -2 2 - "$(guz "$INTDIR/sequences.tsv.gz")" \
		| $CMD_GZIP - > "$INTDIR/peptides_by_original.tsv.gz"
	log "Finished the substitution of equalized AA's by ID's for the peptides with status $?."
}

calculate_original_fas() {
	have "$INTDIR/peptides_by_original.tsv.gz" || return
	log "Started the calculation of original FA's."
	mkfifo "peptides_orig"
	zcat "$INTDIR/peptides_by_original.tsv.gz" | cut -f3,5 > "peptides_orig" &
	node "$CURRENT_LOCATION/helper_scripts/FunctionalAnalysisPeptides.js" "peptides_orig" "$(gz "$INTDIR/FAs_original.tsv.gz")"
	rm "peptides_orig"
	log "Finished the calculation of original FA's."
}

sort_peptides() {
	have "$INTDIR/peptides_by_original.tsv.gz" || return
	log "Started sorting the peptides table."
	mkdir -p "$OUTPUT_DIR"
	zcat "$INTDIR/peptides_by_original.tsv.gz" \
		| LC_ALL=C $CMD_SORT -n \
		| $CMD_GZIP - > "$OUTPUT_DIR/peptides.tsv.gz"
	log "Finished sorting the peptides table."
}

create_sequence_table() {
	have "$INTDIR/LCAs_original.tsv.gz" "$INTDIR/LCAs_equalized.tsv.gz" "$INTDIR/FAs_original.tsv.gz" "$INTDIR/FAs_equalized.tsv.gz" "$INTDIR/sequences.tsv.gz" || return
	log "Started the creation of the sequences table."
	mkdir -p "$OUTPUT_DIR"
	mkfifo "olcas" "elcas" "ofas" "efas"
	zcat "$INTDIR/LCAs_original.tsv.gz"  | gawk '{ printf("%012d\t%s\n", $1, $2) }' > "olcas" &
	zcat "$INTDIR/LCAs_equalized.tsv.gz" | gawk '{ printf("%012d\t%s\n", $1, $2) }' > "elcas" &
	zcat "$INTDIR/FAs_original.tsv.gz"   | gawk '{ printf("%012d\t%s\n", $1, $2) }' > "ofas" &
	zcat "$INTDIR/FAs_equalized.tsv.gz"  | gawk '{ printf("%012d\t%s\n", $1, $2) }' > "efas" &
	zcat "$INTDIR/sequences.tsv.gz"      | gawk '{ printf("%012d\t%s\n", $1, $2) }' \
		| join --nocheck-order -a1 -e '\N' -t '	' -o "1.1 1.2 2.2" - "olcas" \
		| join --nocheck-order -a1 -e '\N' -t '	' -o "1.1 1.2 1.3 2.2" - "elcas" \
		| join --nocheck-order -a1 -e '\N' -t '	' -o '1.1 1.2 1.3 1.4 2.2' - "ofas" \
		| join --nocheck-order -a1 -e '\N' -t '	' -o '1.1 1.2 1.3 1.4 1.5 2.2' - "efas" \
		| sed 's/^0*//' | $CMD_GZIP - > "$OUTPUT_DIR/sequences.tsv.gz"
	rm "olcas" "elcas" "ofas" "efas"
	log "Finished the creation of the sequences table."
}

fetch_ec_numbers() {
	log "Started creating EC numbers."
	mkdir -p "$OUTPUT_DIR"
	{
		curl -s "$EC_CLASS_URL" | grep '^[1-9]' | sed 's/\. *\([-0-9]\)/.\1/g' | sed 's/  */\t/' | sed 's/\.*$//'
		curl -s "$EC_NUMBER_URL" | grep -E '^ID|^DE' | gawk '
			BEGIN { FS="   "
			        OFS="\t" }
			/^ID/ { if(id != "") { print id, name }
			        name = ""
			        id = $2 }
			/^DE/ { gsub(/.$/, "", $2)
			        name = name $2 }
			END   { print id, name }'
	} | cat -n | sed 's/^ *//' | $CMD_GZIP - > "$OUTPUT_DIR/ec_numbers.tsv.gz"
	log "Finished creating EC numbers."
}

fetch_go_terms() {
	log "Started creating GO terms."
	mkdir -p "$OUTPUT_DIR"
	curl -Ls "$GO_TERM_URL" | gawk '
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
			type = "" }' | $CMD_GZIP - > "$OUTPUT_DIR/go_terms.tsv.gz"
	log "Finished creating GO terms."
}

fetch_interpro_entries() {
	log "Started creating InterPro Entries."
	mkdir -p "$OUTPUT_DIR"
	curl -s "$INTERPRO_URL" | grep '^IPR' | cat -n | sed 's/^ *//' | $CMD_GZIP - > "$OUTPUT_DIR/interpro_entries.tsv.gz"
	log "Finished creating InterPro Entries."
}

#dot: uniprot_entries -> create_kmer_index
#dot: taxons -> create_kmer_index
#dot: create_kmer_index [shape=box,color="#4e79a7"]
#dot: create_kmer_index -> kmer_index
#dot: kmer_index [color="#f28e2b"]
create_kmer_index() {
	have "$OUTPUT_DIR/uniprot_entries.tsv.gz" "$OUTPUT_DIR/taxons.tsv.gz" || return
	log "Started the construction of the $KMER_LENGTH-mer index."
	for PREFIX in A C D E F G H I K L M N P Q R S T V W Y; do
		pv -N $PREFIX "$OUTPUT_DIR/uniprot_entries.tsv.gz" \
			| gunzip \
			| cut -f4,7 \
			| grep "^[0-9]*	[ACDEFGHIKLMNPQRSTVWY]*$" \
			| umgap splitkmers -k"$KMER_LENGTH" \
			| sed -n "s/^$PREFIX//p" \
			| LC_ALL=C $CMD_SORT \
			| sed "s/^/$PREFIX/"
	done \
			| umgap joinkmers "$(guz "$OUTPUT_DIR/taxons.tsv.gz")" \
			| cut -d'	' -f1,2 \
			| umgap buildindex \
			> "$OUTPUT_DIR/$KMER_LENGTH-mer.index"
	log "Finished the construction of the $KMER_LENGTH-mer index."
}

#dot: sequences -> create_tryptic_index
#dot: create_tryptic_index [shape=box,color="#4e79a7"]
#dot: create_tryptic_index -> tryptic_index
#dot: tryptic_index [color="#f28e2b"]
create_tryptic_index() {
	have "$TABDIR/sequences.tsv.gz" || return
	log "Started the construction of the tryptic index."
	pv "$TABDIR/sequences.tsv.gz" \
		| gunzip \
		| cut -f2,3 \
		| grep -v "\\N" \
		| umgap buildindex \
		> "$TABDIR/tryptic.index"
	log "Finished the construction of the tryptic index."
}

### Run the actual construction process itself.

case "$BUILD_TYPE" in
database)
	create_taxon_tables
	download_and_convert_all_sources
	create_tables_and_filter
	echo "Created tables!"
	join_equalized_pepts_and_entries &
	pid1=$!
	join_original_pepts_and_entries &
	pid2=$!
	wait $pid1
	wait $pid2
	number_sequences
	reportProgress "-1" "Calculating lowest common ancestors." 6
	calculate_equalized_lcas &
	pid1=$!
	calculate_original_lcas &
	pid2=$!
	wait $pid1
	wait $pid2
	rm "$INTDIR/aa_sequence_taxon_equalized.tsv.gz"
	rm "$INTDIR/aa_sequence_taxon_original.tsv.gz"
	substitute_equalized_aas
	rm "$INTDIR/peptides.tsv.gz"
	substitute_original_aas
	reportProgress "-1" "Calculating functional annotations." 7
	calculate_equalized_fas &
	pid1=$!
	calculate_original_fas &
	pid2=$!
	wait $pid1
	wait $pid2
	rm "$INTDIR/peptides_by_equalized.tsv.gz"
	reportProgress "-1" "Sorting peptides." 8
	sort_peptides
	rm "$INTDIR/peptides_by_original.tsv.gz"
	reportProgress "-1" "Creating sequence table." 9
	create_sequence_table
	rm "$INTDIR/LCAs_original.tsv.gz"
	rm "$INTDIR/LCAs_equalized.tsv.gz"
	rm "$INTDIR/FAs_original.tsv.gz"
	rm "$INTDIR/FAs_equalized.tsv.gz"
	rm "$INTDIR/sequences.tsv.gz"
	reportProgress "-1" "Fetching EC numbers." 10
	fetch_ec_numbers
	reportProgress "-1" "Fetching GO terms." 11
	fetch_go_terms
	reportProgress "-1" "Fetching InterPro entries." 12
	fetch_interpro_entries
	reportProgress "-1" "Computing database indices" 13
	ENTRIES=$(zcat "$OUTPUT_DIR/uniprot_entries.tsv.gz" | wc -l)
	echo "Database contains: ##$ENTRIES##"
	;;
static-database)
	if ! have "$TABDIR/taxons.tsv.gz"; then
		create_taxon_tables
	fi
	fetch_ec_numbers
	fetch_go_terms
	fetch_interpro_entries
	;;
kmer-index)
	checkdep pv
	checkdep umgap "umgap crate (for umgap buildindex)"

	if ! have "$OUTPUT_DIR/taxons.tsv.gz"; then
		create_taxon_tables
	fi
	if ! have "$OUTPUT_DIR/uniprot_entries.tsv.gz"; then
		download_and_convert_all_sources
		create_tables_and_filter
	fi
	create_kmer_index
	;;
tryptic-index)
	checkdep pv
	checkdep umgap "umgap crate (for umgap buildindex)"

	if ! have "$TABDIR/taxons.tsv.gz"; then
		create_taxon_tables
	fi
	if ! have "$TABDIR/sequences.tsv.gz"; then
		download_and_convert_all_sources
		create_tables_and_filter
		join_equalized_pepts_and_entries
		join_original_pepts_and_entries
		number_sequences
		calculate_equalized_lcas
		calculate_original_lcas
		substitute_equalized_aas
		calculate_equalized_fas
		substitute_original_aas
		calculate_original_fas
		create_sequence_table
	fi
	create_tryptic_index
	;;
esac
