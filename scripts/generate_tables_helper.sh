################################################################################
# This file contains a collection of variables and helper functions shared     #
# between the `generate_sa_tables.sh` and `generate_umgap_tables.sh` scripts.  #
################################################################################

# All references to an external script should be relative to the location of this script.
# See: http://mywiki.wooledge.org/BashFAQ/028
CURRENT_LOCATION="${BASH_SOURCE%/*}"

################################################################################
#                                    Imports                                   #
################################################################################

source "${CURRENT_LOCATION}/general_helpers.sh"

################################################################################
#                            Variables and options                             #
################################################################################

# Required to reset the temporary directory after running the script
OLD_TMPDIR="$TMPDIR"

# URLs that should be used to download the UniProtKB database in dat.gz format
declare -A SOURCE_URLS=(
    [swissprot]="https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.dat.gz"
    [trembl]="https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_trembl.dat.gz"
)

# Some default values for the utilities used by this script
CMD_LZ4="lz4 -c" # Which pipe compression command should I use for .lz4 files?
CMD_LZ4CAT="lz4 -dc" # Which decompression command should I use for .lz4 files?
CMD_AWK="gawk"

################################################################################
#                            Helper Functions                                  #
################################################################################

################################################################################
# clean                                                                        #
#                                                                              #
# This function removes all temporary files that have been created by this     #
# script. It cleans the contents of the temporary directory and resets the     #
# TMPDIR environment variable to its original value.                           #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory used to store temporary files                #
#   UNIPEPT_TEMP_CONSTANT - The constant used to create temporary file paths   #
#   OLD_TMPDIR        - Original TMPDIR value to restore                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
clean() {
	# Clean contents of temporary directory
	rm -rf "${TEMP_DIR:?}/$UNIPEPT_TEMP_CONSTANT"
	export TMPDIR="$OLD_TMPDIR"
}

################################################################################
# terminateAndExit                                                             #
#                                                                              #
# Stops the script and removes all temporary files that are created by this    #
# script. Prints an error message to stderr and exits with status code 1.      #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr                                                   #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
terminateAndExit() {
	echo "Error: execution of the script was cancelled by the user." 1>&2
	echo ""
	clean
	exit 1
}

################################################################################
# errorAndExit                                                                 #
#                                                                              #
# Can be called when an error has occurred during the execution of the script. #
# This function will inform the user of what error occurred, where it occurred,#
# and what command was being executed when it happened. It will then properly  #
# exit the script, cleaning up any temporary files first.                      #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 (optional)     - Additional error message to display                    #
#                                                                              #
# Outputs:                                                                     #
#   Error details to stderr                                                    #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 2                                                  #
################################################################################
errorAndExit() {
  local exit_status="$?"        # Capture the exit status of the last command
  local line_no=${BASH_LINENO[0]}  # Get the line number where the error occurred
  local command="${BASH_COMMAND}"  # Get the command that was executed

	echo "Error: the script experienced an error while trying to build the requested database." 1>&2
	echo "Error details:" 1>&2
  echo "Command '$command' failed with exit status $exit_status at line $line_no." 1>&2

	if [[ -n "$1" ]]
	then
	  echo "$1" 1>&2
  fi
	echo "" 1>&2
	clean
	exit 2
}

################################################################################
# printUnknownOptionAndExit                                                    #
#                                                                              #
# Informs the user that the syntaxis provided for this script is incorrect and #
# exits with status code 3.                                                    #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr                                                    #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 3                                                   #
################################################################################
printUnknownOptionAndExit() {
	echo "Error: unknown invocation of script. Consult the information below for more details on how to use this script."
	echo "" 1>&2
	printHelp
	exit 3
}

################################################################################
# checkDirectoryAndCreate                                                      #
#                                                                              #
# Checks if the given specified location is a valid directory. If the given    #
# path points to a non-existing item, a new directory will be created at this  #
# location. The script will exit with status code 4 if an invalid path is      #
# presented.                                                                   #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Path to check or create                                               #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr if the path is invalid                             #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 4 if the path is invalid                            #
################################################################################
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

################################################################################
# reportProgress                                                               #
#                                                                              #
# Logs the progress of an ongoing task as a percentage. The progress value     #
# can either be passed as an argument or provided through stdin. If the        #
# progress is indeterminate or continuously updated, it can be streamed        #
# through stdin.                                                               #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Progress value as a percentage (0-100). Use "-" to read from stdin    #
#   $2 - A description or label for the task being logged                      #
#                                                                              #
# Outputs:                                                                     #
#   Progress message with the format "<label> -> <progress>%" to stdout        #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
reportProgress() {
  # Value between 0 and 100 (-1 for indeterminate progress)
  if [[ "$1" == "-" ]]
  then
    while read -r PROGRESS
    do
      log "$2 -> ${PROGRESS}%"
    done
  else
    PROGRESS="$1"
    log "$2 -> ${PROGRESS}%"
  fi
}

################################################################################
# lz                                                                           #
#                                                                              #
# Creates a named pipe (FIFO) for the provided file and prepares it to receive #
# compressed data using the LZ4 algorithm. The compressed output is written    #
# to the specified file. Input to the lz function is uncompressed data.        #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory to store intermediate pipes                  #
#   UNIPEPT_TEMP_CONSTANT - Sub-directory constant for intermediate storage    #
#   CMD_LZ4           - Command or path to the lz4 binary                      #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Path to the file where the compressed output will be stored           #
#                                                                              #
# Outputs:                                                                     #
#   The path to the created FIFO                                               #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
lz() {
	fifo="$(uuidgen)-$(basename "$1")"
	rm -f "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	mkfifo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	echo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	mkdir -p "$(dirname "$1")"
	{ $CMD_LZ4 - < "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" > "$1" && rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" || kill "$self"; } > /dev/null &
}

################################################################################
# luz                                                                          #
#                                                                              #
# Creates a named pipe (FIFO) for the provided file and decompresses data from #
# the file using the LZ4 algorithm. The decompressed output is passed through  #
# the FIFO.                                                                    #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory to store intermediate pipes                  #
#   UNIPEPT_TEMP_CONSTANT - Sub-directory constant for intermediate storage    #
#   CMD_LZ4CAT        - Command or path to the lz4 decompression binary        #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Path to the compressed input file                                     #
#                                                                              #
# Outputs:                                                                     #
#   The path to the created FIFO                                               #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
luz() {
	fifo="$(uuidgen)-$(basename "$1")"
	rm -f "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	mkfifo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	echo "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo"
	{ $CMD_LZ4CAT "$1" > "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" && rm "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/$fifo" || kill "$self"; } > /dev/null &
}

################################################################################
# have                                                                         #
#                                                                              #
# Checks if all files passed as arguments exist.                               #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $@ - List of file paths to check                                           #
#                                                                              #
# Outputs:                                                                     #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   0 if all files exist, 1 otherwise                                          #
################################################################################
have() {
	if [ "$#" -gt 0 -a -e "$1" ]; then
		shift
		have "$@"
	else
		[ "$#" -eq 0 ]
	fi
}

################################################################################
# checkdep                                                                     #
#                                                                              #
# Checks if a specific dependency is installed on the current system. If the   #
# dependency is missing, an error message is displayed, indicating to the user #
# what needs to be installed. The script exits with status code 6 if the       #
# dependency is not met.                                                       #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Name of the dependency to check (must be recognizable by the system)  #
#   $2 (optional) - Friendly name of the dependency to display in the error    #
#                   message if it's missing                                    #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr if the dependency is not found                     #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 6 if the dependency is not installed                #
################################################################################
checkdep() {
    which "$1" > /dev/null 2>&1 || hash "$1" > /dev/null 2>&1 || {
        echo "Unipept database builder requires ${2:-$1} to be installed." >&2
        exit 6
    }
}

################################################################################
# log                                                                          #
#                                                                              #
# Logs a timestamped message to standard output. The format includes an epoch  #
# timestamp, date, and time for better traceability of script activity.        #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $@ - The message to log                                                    #
#                                                                              #
# Outputs:                                                                     #
#   The timestamped log message to stdout                                      #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
log() { echo "$(date +'[%s (%F %T)]')" "$@"; }

################################################################################
# collapse                                                                     #
#                                                                              #
# Read from stdin. Each input line consists of two tab-separated columns       #
# (key, value). This function takes the key and collapses all values together  #
# using a semicolon (;)                                                        #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Collapsed pairs (key, [value])                                             #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
collapse() {
# shellcheck disable=SC2016
$CMD_AWK '
  BEGIN { FS = "\t" }
  {
   if ($1 == prev) {
     out = out ";" $2
   } else {
     if (NR > 1) print prev "\t" out
     prev = $1
     out = $2
   }
  }
  END {
   if (NR > 0) print prev "\t" out
  }
'
}

################################################################################
# build_binaries                                                               #
#                                                                              #
# Builds the release binaries for the rust-utils project                       #
# This function ensures that all the required binaries are available for the   #
# database building process.                                                   #
#                                                                              #
# Globals:                                                                     #
#   CURRENT_LOCATION - Directory where the script is currently running         #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
build_binaries() {
  packages=$(echo "$@" | sed 's/[^ ]*/-p &/g')
  log "Started building Rust utilities"
  cd "$CURRENT_LOCATION"/rust-utils
  cargo build --release --quiet $packages
  cd - > /dev/null
  log "Finished building Rust utilities"
}

################################################################################
# extract_uniprot_version                                                      #
#                                                                              #
# Fetches the version number of the current UniProtKB release from its         #
# metadata file and stores the formatted version in a `.version` file in the   #
# specified output directory. The version is retrieved from an XML file and    #
# converted from YYYY_MM format to YYYY.MM before saving.                      #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Output directory where the `.version` file will be stored             #
#                                                                              #
# Outputs:                                                                     #
#   .version - File containing the formatted UniProtKB release version         #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
extract_uniprot_version() {
  local output_dir="$1"

  # URL of the XML file
  local xml_url="https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/RELEASE.metalink"

  # Use curl to download the XML content
  local xml_content
  xml_content=$(curl -s "$xml_url")

  # Use xmllint to parse and extract the version tag value
  local version_value
  version_value=$(echo "$xml_content" | xmllint --xpath 'string(//*[local-name()="version"])' -)

  # Check if the version value is not empty
  if [[ -z "$version_value" ]]; then
    errorAndExit "No valid version tag found for UniProt."
  fi

  # Convert YYYY_MM to YYYY.MM
  local formatted_version
  formatted_version="${version_value/_/.}"

  # Write the formatted version to the .version file
  echo "$formatted_version" > "$output_dir/.version"
  echo "Version $formatted_version written to .version file."
}

################################################################################
# download_uniprot                                                             #
#                                                                              #
# Downloads UniProtKB databases specified as a comma-separated list in the     #
# first argument ($1). The function supports "swissprot" and "trembl". For     #
# each database type, it attempts to download and decompress the UniProtKB     #
# files and writes them to stdout                                              #
#                                                                              #
# Globals:                                                                     #
#   CURRENT_LOCATION   - Current script directory                              #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Comma-separated list of database sources to download. Supported       #
#                                                                              #
# Outputs:                                                                     #
#   None                                                                       #
#                                                                              #
# Returns:                                                                     #
#   stream of decompressed UniProtKB entries (stdout)                          #
################################################################################
download_uniprot() {
  local old_ifs="$IFS"
  IFS=","
  local db_types_array=($1)
  IFS="$old_ifs"

  local idx=0

  while [[ "$idx" -ne "${#db_types_array}" ]] && [[ -n $(echo "${db_types_array[$idx]}" | sed "s/\s//g") ]]
  do
    local db_type=${db_types_array[$idx]}
    local db_source=${SOURCE_URLS["$db_type"]}

    log "Started downloading UniProtKB - $db_type."

    # Where should we store the index of this converted database.
    local db_output_dir="${temp_dir:?}/${temp_constant}/$db_type"

    # Remove previous database (if it exist) and continue building the new database.
    rm -rf "$db_output_dir"
    mkdir -p "$db_output_dir"

    # Extract the total size of the database that's being downloaded. This is required for pv to know which percentage
    # of the total download has been processed.
    local size="$(curl -I "$db_source" -s | grep -i content-length | tr -cd '[0-9]')"

    # Effectively download the database and convert to a tabular format
    curl --continue-at - --create-dirs "$db_source" --silent \
    | pv -i 5 -n -s "$size" 2> >(reportProgress - "Downloading database for $db_type" >&2) \
    | pigz -dc

    log "Finished downloading UniProtKB - $db_type."

    idx=$((idx + 1))
  done
}

################################################################################
# download_taxdmp                                                              #
#                                                                              #
# Downloads the taxdmp file required for generating taxon tables. This function#
# attempts to fetch the file from a self-hosted source using the GitHub API.   #
# If the self-hosted source is unavailable, a fallback URL is used.            #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   taxdmp.zip                                                                 #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
download_taxdmp() {
  log "Starting the download of the taxdmp file."

  # Check if our self-hosted version is available or not using the GitHub API
  local latest_release_url="https://api.github.com/repos/unipept/unipept-database/releases/latest"
  local taxon_release_asset_re="unipept/unipept-database/releases/download/[^/]+/taxdmp_v2.zip"

  # Temporary disable the pipefail check (cause egrep can exit with code 1 if nothing is found).
  set +eo pipefail
  local self_hosted_url=$(curl -s "$latest_release_url" | egrep -o "$taxon_release_asset_re")
  set -eo pipefail


  if [ "$self_hosted_url" ]
  then
    log "Using self-hosted taxon dump."
    local taxon_url="https://github.com/$self_hosted_url"
  else
    log "Using fallback taxon dump."
    local taxon_url="https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdmp.zip"
  fi

  curl -L --create-dirs --silent --output "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/taxdmp.zip" "$taxon_url"

  log "Finished downloading the taxdmp file."
}

################################################################################
# create_taxon_tables                                                          #
#                                                                              #
# Generates the taxon and lineage tables required for the database by          #
# downloading, parsing, processing, and filtering the data files. This function#
# downloads the latest taxon dump, processes the necessary files, filters out  #
# ranks not supported by Unipept, and generates the appropriate output files   #
# in the specified directory.                                                  #
#                                                                              #
# Globals:                                                                     #
#   TEMP_DIR          - Directory used to store temporary files                #
#   UNIPEPT_TEMP_CONSTANT - Sub-directory constant for taxon dump storage      #
#   CURRENT_LOCATION  - Current script directory                               #
#   OUTPUT_DIR        - Directory where output files are created               #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Temporary directory used to store intermediate files                  #
#   $2 - Temporary constant to identify this script's files in the temp dir    #
#   $3 - Output directory where the resulting files are created                #
#                                                                              #
# Outputs:                                                                     #
#   taxons.tsv.lz4                                                             #
#   lineages.tsv.lz4                                                           #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
create_taxon_tables() {
	log "Started creating the taxon and lineage tables."

	local temp_dir="$1"
	local temp_constant="$2"
	local output_dir="$3"

  download_taxdmp
  unzip -qq "$temp_dir/$temp_constant/taxdmp.zip" "names.dmp" "nodes.dmp" -d "$temp_dir/$temp_constant"
  rm "$temp_dir/$temp_constant/taxdmp.zip"

  # Replace ranks not used by Unipept by "no rank". And replace the no_rank of viruses by domain.
  sed -i'' -e 's/subcohort/no rank/' -e 's/cohort/no rank/' \
    -e 's/subsection/no rank/' -e 's/section/no rank/' \
    -e 's/series/no rank/' -e 's/biotype/no rank/' \
    -e 's/serogroup/no rank/' -e 's/morph/no rank/' \
    -e 's/genotype/no rank/' -e 's/subvariety/no rank/' \
    -e 's/pathogroup/no rank/' -e 's/forma specialis/no rank/' \
    -e 's/serotype/no rank/' -e 's/clade/no rank/' \
    -e 's/isolate/no rank/' -e 's/infraclass/no rank/' \
    -e 's/acellular root/no rank/' -e 's/cellular root/no rank/' \
    -e 's/parvorder/no rank/' -e 's/no_rank/domain/' "$temp_dir/$temp_constant/nodes.dmp"

  log "Parsing names.dmp and nodes.dmp files"
  mkdir -p "$output_dir"
  "$CURRENT_LOCATION"/rust-utils/target/release/taxdmp-parser \
    --names "$temp_dir/$temp_constant/names.dmp" \
    --nodes "$temp_dir/$temp_constant/nodes.dmp" \
    --taxa "$(lz "$output_dir/taxons.tsv.lz4")" \
    --lineages "$(lz "$output_dir/lineages.tsv.lz4")"

  rm "$temp_dir/$temp_constant/names.dmp" "$temp_dir/$temp_constant/nodes.dmp"
  log "Finished creating the taxon and lineage tables."
}

################################################################################
# fetch_ec_numbers                                                             #
#                                                                              #
# Fetches EC (Enzyme Commission) numbers and descriptions, combining the EC    #
# class data and individual entries. The resulting data is saved to a          #
# compressed tab-delimited file.                                               #
#                                                                              #
# Globals:                                                                     #
#   CMD_AWK      - Command or path to the awk binary                           #
#   CMD_LZ4      - Command or path to the lz4 binary                           #
#   OUTPUT_DIR   - Directory to save the output files                          #
#                                                                              #
# Arguments:                                                                   #
#   $1            - Output directory                                           #
#                                                                              #
# Outputs:                                                                     #
#   ec_numbers.tsv.lz4 - Compressed table of EC numbers and descriptions       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
fetch_ec_numbers() {
	local output_dir="$1"

	log "Started creating EC numbers."

	local ec_class_url="https://ftp.expasy.org/databases/enzyme/enzclass.txt"
  local ec_number_url="https://ftp.expasy.org/databases/enzyme/enzyme.dat"

	mkdir -p "$output_dir"
	{
		curl -s "$ec_class_url" | grep '^[1-9]' | sed 's/\. *\([-0-9]\)/.\1/g' | sed 's/  */\t/' | sed 's/\.*$//'
		curl -s "$ec_number_url" | grep -E '^ID|^DE' | $CMD_AWK '
			BEGIN { FS="   "
			        OFS="\t" }
			/^ID/ { if(id != "") { print id, name }
			        name = ""
			        id = $2 }
			/^DE/ { gsub(/.$/, "", $2)
			        name = name $2 }
			END   { print id, name }'
	} | cat -n | sed 's/^ *//' | $CMD_LZ4 - > "$output_dir/ec_numbers.tsv.lz4"
	log "Finished creating EC numbers."
}

################################################################################
# fetch_go_terms                                                               #
#                                                                              #
# Fetches Gene Ontology (GO) terms, parses their attributes, and generates a   #
# compressed tab-delimited file of GO identifiers and their related data.      #
#                                                                              #
# Globals:                                                                     #
#   CMD_AWK     - Command or path to the awk binary                            #
#   CMD_LZ4     - Command or path to the lz4 binary                            #
#                                                                              #
# Arguments:                                                                   #
#   $1            - Output directory                                           #
#                                                                              #
# Outputs:                                                                     #
#   go_terms.tsv.lz4 - Compressed table of GO terms and their attributes       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
fetch_go_terms() {
  local output_dir="$1"

	log "Started creating GO terms."

	local go_term_url="http://geneontology.org/ontology/go-basic.obo"

	mkdir -p "$output_dir"
	curl -Ls "$go_term_url" | $CMD_AWK '
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
			type = "" }' | $CMD_LZ4 - > "$output_dir/go_terms.tsv.lz4"
	log "Finished creating GO terms."
}

################################################################################
# fetch_interpro_entries                                                       #
#                                                                              #
# Fetches InterPro database entries, extracts those that start with 'IPR', and #
# saves them into a compressed tab-delimited file.                             #
#                                                                              #
# Globals:                                                                     #
#   CMD_LZ4      - Command or path to the lz4 binary                           #
#                                                                              #
# Arguments:                                                                   #
#   $1            - Output directory                                           #
#                                                                              #
# Outputs:                                                                     #
#   interpro_entries.tsv.lz4 - Compressed table of InterPro entries            #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
fetch_interpro_entries() {
  local output_dir="$1"

	log "Started creating InterPro Entries."

	local interpro_url="http://ftp.ebi.ac.uk/pub/databases/interpro/current_release/entry.list"

	mkdir -p "$output_dir"
	curl -s "$interpro_url" | grep '^IPR' | cat -n | sed 's/^ *//' | $CMD_LZ4 - > "$output_dir/interpro_entries.tsv.lz4"
	log "Finished creating InterPro Entries."
}

################################################################################
# fetch_reference_proteomes                                                    #
#                                                                              #
# Fetches UniProt Reference Proteome data and generates a compressed           #
# tab-delimited file containing relevant fields.                               #
#                                                                              #
# Globals:                                                                     #
#   CMD_LZ4                - Command or path to the lz4 binary                 #
#                                                                              #
# Arguments:                                                                   #
#   $1            - Output directory                                           #
#                                                                              #
# Outputs:                                                                     #
#   reference_proteomes.tsv.lz4 - Compressed table of UniProt Reference        #
#                                 Proteomes                                    #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
fetch_reference_proteomes() {
  local output_dir="$1"

  log "Started creating UniProt Reference Proteomes."

  local reference_proteome_url="https://rest.uniprot.org/proteomes/stream?fields=upid,organism_id,protein_count&format=tsv&query=(*)+AND+(proteome_type:1)"

  mkdir -p "$output_dir"
  curl -s "$reference_proteome_url" | tail -n +2 | sort | $CMD_LZ4 - > "$output_dir/reference_proteomes.tsv.lz4"
  log "Finished creating UniProt Reference Proteomes."
}
