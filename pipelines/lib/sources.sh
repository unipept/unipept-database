# shellcheck shell=bash
################################################################################
# The steps that download and prepare the source data for both pipelines.      #
# Sourced after common.sh, never run.                                          #
################################################################################

################################################################################
#                            Variables and options                             #
################################################################################

# Every source below can be read from somewhere else by setting UNIPEPT_<NAME>_URL: the name of
# the local variable holding it in capitals, or the database source for the two below. A file://
# URL works, for a build that reads local files.

# URLs that should be used to download the UniProtKB database in dat.gz format
declare -A SOURCE_URLS=(
    [swissprot]="https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.dat.gz"
    [trembl]="https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/uniprot_trembl.dat.gz"
)

################################################################################
#                                  Steps                                       #
################################################################################

################################################################################
# extract_uniprot_version                                                      #
#                                                                              #
# Fetches the version number of the current UniProtKB release from its         #
# metadata file and stores the formatted version in a `.version` file in the   #
# specified output directory. The version is retrieved from an XML file and    #
# converted from YYYY_MM format to YYYY.MM before saving.                      #
#                                                                              #
# Globals:                                                                     #
#   UNIPEPT_RELEASE_METALINK_URL - Replaces the metalink URL                   #
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

  local release_metalink_url="${UNIPEPT_RELEASE_METALINK_URL:-https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/RELEASE.metalink}"

  # Use curl to download the XML content
  local xml_content
  xml_content=$(curl -s "$release_metalink_url")

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
#   UNIPEPT_<SOURCE>_URL - Replaces the URL of that database source            #
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
  local db_types_array
  IFS="," read -r -a db_types_array <<< "$1"

  local idx=0

  while [[ "$idx" -ne "${#db_types_array}" ]] && [[ -n "${db_types_array[$idx]//[[:space:]]/}" ]]
  do
    local db_type=${db_types_array[$idx]}
    local db_source_override="UNIPEPT_${db_type^^}_URL"
    local db_source="${!db_source_override:-${SOURCE_URLS["$db_type"]}}"

    log "Started downloading UniProtKB - $db_type."

    # Where should we store the index of this converted database.
    local db_output_dir="${temp_dir:?}/${temp_constant}/$db_type"

    # Remove previous database (if it exist) and continue building the new database.
    rm -rf "$db_output_dir"
    mkdir -p "$db_output_dir"

    # Extract the total size of the database that's being downloaded. This is required for pv to know which percentage
    # of the total download has been processed.
    local size
    size="$(curl -I "$db_source" -s | grep -i content-length | tr -cd '0-9')"

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
# UNIPEPT_TAXDMP_URL replaces the dump, and the lookup of it.                  #
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

  local taxdmp_url

  if [ -n "${UNIPEPT_TAXDMP_URL:-}" ]
  then
    log "Using the taxon dump at UNIPEPT_TAXDMP_URL."
    taxdmp_url="$UNIPEPT_TAXDMP_URL"
  else
    # Check if our self-hosted version is available or not using the GitHub API
    local latest_release_url="https://api.github.com/repos/unipept/unipept-database/releases/latest"
    local taxon_release_asset_re="unipept/unipept-database/releases/download/[^/]+/taxdmp_v2.zip"

    # Temporary disable the pipefail check (cause grep can exit with code 1 if nothing is found).
    set +eo pipefail
    local self_hosted_url
    self_hosted_url=$(curl -s "$latest_release_url" | grep -E -o "$taxon_release_asset_re")
    set -eo pipefail

    if [ "$self_hosted_url" ]
    then
      log "Using self-hosted taxon dump."
      taxdmp_url="https://github.com/$self_hosted_url"
    else
      log "Using fallback taxon dump."
      taxdmp_url="https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdmp.zip"
    fi
  fi

  # shellcheck disable=SC2153 # TEMP_DIR is set by the build script
  curl -L --create-dirs --silent --output "$TEMP_DIR/$UNIPEPT_TEMP_CONSTANT/taxdmp.zip" "$taxdmp_url"

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
    -e 's/acellular root/domain/' -e 's/cellular root/no rank/' \
    -e 's/parvorder/no rank/' "$temp_dir/$temp_constant/nodes.dmp"

  log "Parsing names.dmp and nodes.dmp files"
  mkdir -p "$output_dir"
  "$RUST_BIN_DIR"/taxdmp-parser \
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
#   UNIPEPT_EC_CLASS_URL, UNIPEPT_EC_NUMBER_URL - Replace the EC URLs          #
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
# shellcheck disable=SC2016 # the single-quoted strings are awk programs
fetch_ec_numbers() {
	local output_dir="$1"

	log "Started creating EC numbers."

	local ec_class_url="${UNIPEPT_EC_CLASS_URL:-https://ftp.expasy.org/databases/enzyme/enzclass.txt}"
	local ec_number_url="${UNIPEPT_EC_NUMBER_URL:-https://ftp.expasy.org/databases/enzyme/enzyme.dat}"

	mkdir -p "$output_dir"
	{
		curl -s "$ec_class_url" | grep '^[1-9]' | sed 's/\. *\([-0-9]\)/.\1/g' | sed 's/  */\t/' | sed 's/\.*$//'
		curl -s "$ec_number_url" | grep -E '^ID|^DE' | $CMD_AWK '
			BEGIN { FS="   "
			        OFS="\t" }
			function flush() { if(id != "") { sub(/\.$/, "", name); print id, name } }
			# A name can run over several DE lines, and only the last one ends in a period. A line
			# that ends in a hyphen breaks mid-word, so it takes no space.
			/^ID/ { flush(); name = ""; id = $2 }
			/^DE/ { name = (name == "" ? $2 : (name ~ /-$/ ? name $2 : name " " $2)) }
			END   { flush() }'
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
#   UNIPEPT_GO_TERM_URL - Replaces the GO URL                                  #
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
# shellcheck disable=SC2016 # the single-quoted strings are awk programs
fetch_go_terms() {
  local output_dir="$1"

	log "Started creating GO terms."

	local go_term_url="${UNIPEPT_GO_TERM_URL:-http://geneontology.org/ontology/go-basic.obo}"

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
#   UNIPEPT_INTERPRO_URL - Replaces the InterPro URL                           #
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

	local interpro_url="${UNIPEPT_INTERPRO_URL:-http://ftp.ebi.ac.uk/pub/databases/interpro/current_release/entry.list}"

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
#   UNIPEPT_REFERENCE_PROTEOME_URL - Replaces the proteome query               #
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

  local reference_proteome_url="${UNIPEPT_REFERENCE_PROTEOME_URL:-https://rest.uniprot.org/proteomes/stream?fields=upid,organism_id,protein_count&format=tsv&query=reference:true}"

  mkdir -p "$output_dir"
  curl -s "$reference_proteome_url" | tail -n +2 | sort -k1,1 | $CMD_LZ4 - > "$output_dir/reference_proteomes.tsv.lz4"
  log "Finished creating UniProt Reference Proteomes."
}
