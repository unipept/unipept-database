use std::collections::HashSet;
use anyhow::Context;
use crate::uniprot::UniprotType;

// Constants to aid in parsing
const COMMON_PREFIX_LEN: usize = "ID   ".len();

const ORGANISM_RECOMMENDED_NAME_PREFIX_LEN: usize = "RecName: Full=".len();
const ORGANISM_RECOMMENDED_NAME_EC_PREFIX_LEN: usize = "EC=".len();
const ORGANISM_TAXON_ID_PREFIX_LEN: usize = "OX   NCBI_TaxID=".len();
const VERSION_STRING_FULL_PREFIX_LEN: usize = "DT   08-NOV-2023, entry version ".len();


/// The minimal data we want from an entry out of the UniProtKB datasets
pub struct UniProtDATEntry {
    accession_number: String,
    name: String,
    sequence: String,
    version: String,
    ec_references: Vec<String>,
    go_references: Vec<String>,
    ip_references: Vec<String>,
    taxon_id: String,
}

impl UniProtDATEntry {
    /// Parse an entry out of the lines of a DAT file
    pub fn from_lines(data: &mut Vec<String>) -> anyhow::Result<Self> {
        let mut current_index: usize;

        let accession_number: String;
        let mut version = String::new();
        let mut name = String::new();
        let mut ec_references = Vec::<String>::new();
        let mut go_references = Vec::<String>::new();
        let mut ip_references = Vec::<String>::new();
        let mut taxon_id = String::new();
        let mut sequence = String::new();

        accession_number = parse_ac_number(data).context("Error parsing accession number")?;
        current_index = parse_version(data, &mut version);
        current_index = parse_name_and_ec(data, current_index, &mut ec_references, &mut name);
        current_index = parse_taxon_id(data, current_index, &mut taxon_id);
        current_index = parse_db_references(data, current_index, &mut go_references, &mut ip_references);
        parse_sequence(data, current_index, &mut sequence);

        return Ok(Self {
            accession_number,
            name,
            sequence,
            version,
            ec_references,
            go_references,
            ip_references,
            taxon_id,
        });
    }

    /// Write an entry to stdout
    pub fn write(&self, db_type: &UniprotType) {
        if self.name.is_empty() {
            eprintln!("Could not find a name for entry AC-{}", self.accession_number);
        }

        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            self.accession_number,
            self.sequence,
            self.name,
            self.version,
            self.ec_references.join(";"),
            self.go_references.join(";"),
            self.ip_references.join(";"),
            db_type.to_str(),
            self.taxon_id
        )
    }
}

// Functions to parse an Entry out of a Vec<String>

/// Find the first AC number
fn parse_ac_number(data: &mut Vec<String>) -> anyhow::Result<String> {
    // The AC number is always the second element
    let line = &mut data[1];
    line.drain(..COMMON_PREFIX_LEN);
    let (pre, _) = line.split_once(";").with_context(|| format!("Unable to split \"{line}\" on ';'"))?;
    Ok(pre.to_string())
}

/// Find the version of this entry
fn parse_version(data: &Vec<String>, target: &mut String) -> usize {
    let mut last_field: usize = 2;

    // Skip past previous fields to get to the dates
    while !data[last_field].starts_with("DT") {
        last_field += 1;
    }

    // The date fields are always the third-n elements
    // The version is always the last one
    while data[last_field + 1].starts_with("DT") {
        last_field += 1;
    }

    // Get entry version (has prefix of constant length and ends with a dot)
    let version_end = data[last_field].len() - 1;
    target.push_str(&(data[last_field][VERSION_STRING_FULL_PREFIX_LEN..version_end]));
    last_field + 1
}

/// Parse the name and EC numbers of an entry out of all available DE fields
/// In order of preference:
/// - Last recommended name of protein components
/// - Last recommended name of protein domains
/// - Recommended name of protein itself
/// - Last submitted name of protein components
/// - Last submitted name of protein domains
/// - Submitted name of protein itself
fn parse_name_and_ec(data: &mut Vec<String>, mut idx: usize, ec_references: &mut Vec<String>, target: &mut String) -> usize {
    // Find where the info starts and ends
    while !data[idx].starts_with("DE") {
        idx += 1;
    }

    let mut ec_reference_set = HashSet::new();
    let mut end_index = idx;

    // Track all names in order of preference
    let mut name_indices: [usize; 6] = [usize::MAX; 6];
    const LAST_COMPONENT_RECOMMENDED_IDX: usize = 0;
    const LAST_COMPONENT_SUBMITTED_IDX: usize = 3;
    const LAST_DOMAIN_RECOMMENDED_IDX: usize = 1;
    const LAST_DOMAIN_SUBMITTED_IDX: usize = 4;
    const LAST_PROTEIN_RECOMMENDED_IDX: usize = 2;
    const LAST_PROTEIN_SUBMITTED_IDX: usize = 5;

    // Keep track of which block we are currently in
    // Order in DAT file is always protein -> components -> domain
    let mut inside_domain = false;
    let mut inside_component = false;

    while data[end_index].starts_with("DE") {
        let line = &mut data[end_index];
        line.drain(..COMMON_PREFIX_LEN);

        // Marks the start of a Component
        if line == "Contains:" {
            inside_component = true;
            end_index += 1;
            continue;
        }

        // Marks the start of a Domain
        if line == "Includes:" {
            inside_domain = true;
            end_index += 1;
            continue;
        }

        // Remove all other spaces (consecutive lines have leading spaces we don't care for)
        drain_leading_spaces(line);

        // Keep track of the last recommended name
        if line.starts_with("RecName: Full=") {
            if inside_domain {
                name_indices[LAST_DOMAIN_RECOMMENDED_IDX] = end_index;
            } else if inside_component {
                name_indices[LAST_COMPONENT_RECOMMENDED_IDX] = end_index;
            } else {
                name_indices[LAST_PROTEIN_RECOMMENDED_IDX] = end_index;
            }
        }
        // Find EC numbers
        else if line.starts_with("EC=") {
            let mut ec_target = String::new();
            read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_EC_PREFIX_LEN, &mut ec_target);

            if !ec_reference_set.contains(&ec_target) {
                ec_reference_set.insert(ec_target.clone());
                ec_references.push(ec_target);
            }
        }
        // Keep track of the last submitted name
        else if line.starts_with("SubName: Full=") {
            if inside_domain {
                name_indices[LAST_DOMAIN_SUBMITTED_IDX] = end_index;
            } else if inside_component {
                name_indices[LAST_COMPONENT_SUBMITTED_IDX] = end_index;
            } else {
                name_indices[LAST_PROTEIN_SUBMITTED_IDX] = end_index;
            }
        }

        end_index += 1;
    }

    // Choose a name from the ones we encountered
    // Use the first name that we managed to find, in order
    for idx in name_indices {
        if idx != usize::MAX {
            let line = &mut data[idx];
            read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN, target);
            return end_index;
        }
    }

    end_index
}

/// Find the first NCBI_TaxID of this entry
fn parse_taxon_id(data: &mut Vec<String>, mut idx: usize, target: &mut String) -> usize {
    while !data[idx].starts_with("OX   NCBI_TaxID=") {
        idx += 1;
    }

    let line = &mut data[idx];
    read_until_metadata(line, ORGANISM_TAXON_ID_PREFIX_LEN, target);

    while data[idx].starts_with("OX") {
        idx += 1;
    }

    idx
}

/// Parse GO and InterPro DB references
fn parse_db_references(data: &mut Vec<String>, mut idx: usize, go_references: &mut Vec<String>, ip_references: &mut Vec<String>) -> usize {
    let original_idx = idx;
    let length = data.len();

    // Find where references start
    while !data[idx].starts_with("DR") {
        idx += 1;

        // No references present in this entry
        if idx == length {
            return original_idx;
        }
    }

    // Parse all references
    while data[idx].starts_with("DR") {
        let line = &mut data[idx];
        line.drain(..COMMON_PREFIX_LEN);

        parse_db_reference(line, go_references, ip_references);

        idx += 1;
    }

    idx
}

/// Parse a single GO or InterPro DB reference
fn parse_db_reference(line: &mut String, go_references: &mut Vec<String>, ip_references: &mut Vec<String>) {
    if line.starts_with("GO;") {
        let substr = &line[4..14];
        go_references.push(substr.to_string());
    } else if line.starts_with("InterPro;") {
        let substr = &line[10..19];
        ip_references.push(substr.to_string());
    }
}

/// Parse the peptide sequence for this entry
fn parse_sequence(data: &mut Vec<String>, mut idx: usize, target: &mut String) {
    // Find the beginning of the sequence
    // optionally skip over some fields we don't care for
    while !data[idx].starts_with("SQ") {
        idx += 1;
    }

    // First line of the sequence contains some metadata we don't care for
    idx += 1;

    // Combine all remaining lines
    for line in data.iter_mut().skip(idx) {
        line.drain(..COMMON_PREFIX_LEN);
        target.push_str(&line.replace(" ", ""));
    }
}

/// Read a line until additional metadata starts
/// Some lines end with {blocks between curly brackets} that we don't care for.
fn read_until_metadata(line: &mut String, prefix_len: usize, target: &mut String) {
    line.drain(..prefix_len);

    // The line either contains some metadata, or just ends with a semicolon
    // In the latter case, move the position to the end of the string,
    // so we can pretend it is at a bracket and cut the semicolon out
    // If it contains metadata, this wrapped in curly braces after a space
    // (sometimes there are curly braces inside of the name itself, so just a curly is not enough)
    let mut bracket_index = 0;
    let mut previous_char = '\0';

    for (i, c) in line.chars().enumerate() {
        if c == '{' && previous_char == ' ' {
            bracket_index = i;
            break;
        }

        previous_char = c;
    }

    if bracket_index == 0 {
        bracket_index = line.len();
    }

    target.push_str(&(line[..bracket_index - 1]));
}

/// Remove all leading spaces from a line
/// Internally this just moves a pointer forward so this is very efficient
fn drain_leading_spaces(line: &mut String) {
    // Find the first index that is not a space, and remove everything before
    for (idx, c) in line.chars().enumerate() {
        if c != ' ' {
            line.drain(..idx);
            break;
        }
    }
}