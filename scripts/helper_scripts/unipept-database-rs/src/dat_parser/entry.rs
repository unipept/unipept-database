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
        let mut current_index: usize = 0;

        let accession_number = parse_ac_number(data).context("Error parsing accession number")?;
        let version = parse_version(data, &mut current_index);
        let (name, ec_references) = parse_name_and_ec(data, &mut current_index);
        let taxon_id = parse_taxon_id(data, &mut current_index);
        let (go_references, ip_references) = parse_db_references(data, &mut current_index);
        let sequence = parse_sequence(data, current_index);

        Ok(Self {
            accession_number,
            name,
            sequence,
            version,
            ec_references,
            go_references,
            ip_references,
            taxon_id,
        })
    }

    /// Write an entry to stdout
    pub fn write(&self, db_type: &str) {
        if self.name.is_empty() {
            eprintln!(
                "Could not find a name for entry AC-{}",
                self.accession_number
            );
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
            db_type,
            self.taxon_id
        )
    }
}

// Functions to parse an Entry out of a Vec<String>

/// Find the first AC number
fn parse_ac_number(data: &mut [String]) -> anyhow::Result<String> {
    // The AC number is always the second element
    let line = &mut data[1];
    line.drain(..COMMON_PREFIX_LEN);
    let (pre, _) = line
        .split_once(';')
        .with_context(|| format!("Unable to split \"{line}\" on ';'"))?;
    Ok(pre.to_string())
}

/// Find the version of this entry
fn parse_version(data: &[String], index: &mut usize) -> String {
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
    *index = last_field + 1;
    data[last_field][VERSION_STRING_FULL_PREFIX_LEN..version_end].to_string()
}

/// Parse the name and EC numbers of an entry out of all available DE fields
/// In order of preference:
/// - Last recommended name of protein components
/// - Last recommended name of protein domains
/// - Recommended name of protein itself
/// - Last submitted name of protein components
/// - Last submitted name of protein domains
/// - Submitted name of protein itself
fn parse_name_and_ec(data: &mut [String], index: &mut usize) -> (String, Vec<String>) {
    // Find where the info starts and ends
    while !data[*index].starts_with("DE") {
        *index += 1;
    }

    let mut name = String::new();
    let mut ec_references = Vec::new();
    let mut ec_reference_set = HashSet::new();
    let mut end_index = *index;

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
            let ec_target = read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_EC_PREFIX_LEN);

            // EC numbers sometimes appear multiple times, so use a set to track which ones
            // we've seen before
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
            *index = end_index;
            name = read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN);
            return (name, ec_references);
        }
    }

    (name, ec_references)
}

/// Find the first NCBI_TaxID of this entry
fn parse_taxon_id(data: &mut [String], index: &mut usize) -> String {
    while !data[*index].starts_with("OX   NCBI_TaxID=") {
        *index += 1;
    }

    let line = &mut data[*index];
    let taxon_id = read_until_metadata(line, ORGANISM_TAXON_ID_PREFIX_LEN);

    while data[*index].starts_with("OX") {
        *index += 1;
    }

    taxon_id
}

/// Parse GO and InterPro DB references
fn parse_db_references(data: &mut Vec<String>, index: &mut usize) -> (Vec<String>, Vec<String>) {
    let mut go_references = Vec::new();
    let mut ip_references = Vec::new();
    let original_idx = *index;
    let length = data.len();

    // Find where references start
    while !data[*index].starts_with("DR") {
        *index += 1;

        // No references present in this entry
        if *index == length {
            *index = original_idx;
            return (go_references, ip_references);
        }
    }

    // Parse all references
    while data[*index].starts_with("DR") {
        let line = &mut data[*index];
        line.drain(..COMMON_PREFIX_LEN);

        parse_db_reference(line, &mut go_references, &mut ip_references);

        *index += 1;
    }

    (go_references, ip_references)
}

/// Parse a single GO or InterPro DB reference
fn parse_db_reference(
    line: &mut str,
    go_references: &mut Vec<String>,
    ip_references: &mut Vec<String>,
) {
    if line.starts_with("GO;") {
        let substr = &line[4..14];
        go_references.push(substr.to_string());
    } else if line.starts_with("InterPro;") {
        let substr = &line[10..19];
        ip_references.push(substr.to_string());
    }
}

/// Parse the peptide sequence for this entry
fn parse_sequence(data: &mut [String], mut index: usize) -> String {
    // Find the beginning of the sequence
    // optionally skip over some fields we don't care for
    while !data[index].starts_with("SQ") {
        index += 1;
    }

    // First line of the sequence contains some metadata we don't care for
    index += 1;

    let mut sequence = String::new();

    // Combine all remaining lines
    for line in data.iter_mut().skip(index) {
        line.drain(..COMMON_PREFIX_LEN);
        sequence.push_str(&line.replace(' ', ""));
    }

    sequence
}

/// Read a line until additional metadata starts
/// Some lines end with {blocks between curly brackets} that we don't care for.
fn read_until_metadata(line: &mut String, prefix_len: usize) -> String {
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

    line[..bracket_index - 1].to_string()
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

#[cfg(test)]
mod tests {
    use super::*;

    fn _raw_str_to_strings(v: Vec<&str>) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    fn get_example_entry() -> Vec<String> {
        let v = vec![
            "ID   001R_FRG3G              Reviewed;         256 AA.",
            "AC   P9WPY2; L0TBI1; P0A4Z2; P95014;",
            "DT   28-JUN-2011, integrated into UniProtKB/Swiss-Prot.",
            "DT   19-JUL-2004, sequence version 1.",
            "DT   08-NOV-2023, entry version 44.",
            "DE   RecName: Full=Putative transcription factor 001R;",
            "GN   ORFNames=FV3-001R;",
            "OS   Frog virus 3 (isolate Goorha) (FV-3).",
            "OC   Viruses; Varidnaviria; Bamfordvirae; Nucleocytoviricota; Megaviricetes;",
            "OC   Pimascovirales; Iridoviridae; Alphairidovirinae; Ranavirus; Frog virus 3.",
            "OX   NCBI_TaxID=654924;",
            "OH   NCBI_TaxID=30343; Dryophytes versicolor (chameleon treefrog).",
            "OH   NCBI_TaxID=8404; Lithobates pipiens (Northern leopard frog) (Rana pipiens).",
            "OH   NCBI_TaxID=45438; Lithobates sylvaticus (Wood frog) (Rana sylvatica).",
            "OH   NCBI_TaxID=8316; Notophthalmus viridescens (Eastern newt) (Triturus viridescens).",
            "RN   [1]",
            "RP   NUCLEOTIDE SEQUENCE [LARGE SCALE GENOMIC DNA].",
            "RX   PubMed=15165820; DOI=10.1016/j.virol.2004.02.019;",
            "RA   Tan W.G., Barkman T.J., Gregory Chinchar V., Essani K.;",
            "RT   \"Comparative genomic analyses of frog virus 3, type species of the genus",
            "RT   Ranavirus (family Iridoviridae).\";",
            "RL   Virology 323:70-84(2004).",
            "CC   -!- FUNCTION: Transcription activation. {ECO:0000305}.",
            "CC   ---------------------------------------------------------------------------",
            "CC   Copyrighted by the UniProt Consortium, see https://www.uniprot.org/terms",
            "CC   Distributed under the Creative Commons Attribution (CC BY 4.0) License",
            "CC   ---------------------------------------------------------------------------",
            "DR   EMBL; AY548484; AAT09660.1; -; Genomic_DNA.",
            "DR   RefSeq; YP_031579.1; NC_005946.1.",
            "DR   SwissPalm; Q6GZX4; -.",
            "DR   GeneID; 2947773; -.",
            "DR   KEGG; vg:2947773; -.",
            "DR   Proteomes; UP000008770; Segment.",
            "DR   GO; GO:0046782; P:regulation of viral transcription; IEA:InterPro.",
            "DR   GO; GO:0016743; F:carboxyl- or carbamoyltransferase activity; IEA:UniProtKB-UniRule.",
            "DR   InterPro; IPR007031; Poxvirus_VLTF3.",
            "DR   InterPro; IPR000308; 14-3-3.",
            "DR   Pfam; PF04947; Pox_VLTF3; 1.",
            "PE   4: Predicted;",
            "KW   Activator; Reference proteome; Transcription; Transcription regulation.",
            "FT   CHAIN           1..256",
            "FT                   /note=\"Putative transcription factor 001R\"",
            "FT                   /id=\"PRO_0000410512\"",
            "SQ   SEQUENCE   256 AA;  29735 MW;  B4840739BF7D4121 CRC64;",
            "     MAFSAEDVLK EYDRRRRMEA LLLSLYYPND RKLLDYKEWS PPRVQVECPK APVEWNNPPS",
            "     EKGLIVGHFS GIKYKGEKAQ ASEVDVNKMC CWVSKFKDAM RRYQGIQTCK IPGKVLSDLD",
        ];

        _raw_str_to_strings(v)
    }

    #[test]
    fn test_parse_ac_number() {
        let want = "P9WPY2";
        let mut lines = get_example_entry();
        let got = parse_ac_number(&mut lines).unwrap();

        assert_eq!(got, want);
    }

    #[test]
    fn test_parse_version() {
        let want = "44";
        let mut index = 0;
        let mut lines = get_example_entry();
        let got = parse_version(&mut lines, &mut index);

        assert_eq!(got, want);
    }

    #[test]
    fn test_parse_taxon_id() {
        let want = "654924";
        let mut lines = get_example_entry();
        let mut index: usize = 8;
        let got = parse_taxon_id(&mut lines, &mut index);

        assert_eq!(got, want);
    }

    #[test]
    fn test_parse_db_references() {
        let want_go = vec![String::from("GO:0046782"), String::from("GO:0016743")];
        let want_ip = vec![String::from("IPR007031"), String::from("IPR000308")];
        let mut lines = get_example_entry();
        let mut index: usize = 0;
        let (got_go, got_ip) = parse_db_references(&mut lines, &mut index);

        assert_eq!(got_go, want_go);
        assert_eq!(got_ip, want_ip);
    }

    #[test]
    fn test_parse_db_reference_go() {
        let want = vec![String::from("GO:0046782")];
        let mut line =
            String::from("GO; GO:0046782; P:regulation of viral transcription; IEA:InterPro.");
        let mut target = Vec::new();
        let mut _dummy = Vec::new();
        parse_db_reference(&mut line, &mut target, &mut _dummy);

        assert_eq!(target, want);
        assert!(_dummy.is_empty());
    }

    #[test]
    fn test_parse_db_reference_ip() {
        let want = vec![String::from("IPR007031")];
        let mut line = String::from("InterPro; IPR007031; Poxvirus_VLTF3.");
        let mut target = Vec::new();
        let mut _dummy = Vec::new();
        parse_db_reference(&mut line, &mut _dummy, &mut target);

        assert_eq!(target, want);
        assert!(_dummy.is_empty());
    }

    #[test]
    fn test_parse_sequence() {
        let want = "MAFSAEDVLKEYDRRRRMEALLLSLYYPNDRKLLDYKEWSPPRVQVECPKAPVEWNNPPSEKGLIVGHFSGIKYKGEKAQASEVDVNKMCCWVSKFKDAMRRYQGIQTCKIPGKVLSDLD";
        let mut lines = get_example_entry();
        let got = parse_sequence(&mut lines, 0);
        assert_eq!(got, want);
    }

    #[test]
    fn test_read_until_metadata() {
        let want = "Alanine racemase";
        let mut line = String::from(format!(
            "RecName: Full={want} {{ECO:0000255|HAMAP-Rule:MF_01201}};"
        ));
        let got = read_until_metadata(&mut line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN);
        assert_eq!(got, want);
    }

    #[test]
    fn test_read_until_metadata_with_bracket() {
        let want = "Alanine racemase{text between brackets}";
        let mut line = String::from(format!(
            "RecName: Full={want} {{ECO:0000255|HAMAP-Rule:MF_01201}};"
        ));
        let target = read_until_metadata(&mut line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN);
        assert_eq!(target, want);
    }

    #[test]
    fn test_read_until_metadata_none() {
        let want = "Recommended Name";
        let mut line = String::from(format!("RecName: Full={want};"));
        let target = read_until_metadata(&mut line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN);
        assert_eq!(target, want);
    }

    #[test]
    fn test_drain_spaces() {
        let want = "ABC";
        let mut line = String::from(format!("    {want}"));
        drain_leading_spaces(&mut line);
        assert_eq!(line, want);
    }

    #[test]
    fn test_drain_spaces_none() {
        let want = "This has no leading spaces";
        let mut line = String::from(want);
        drain_leading_spaces(&mut line);
        assert_eq!(line, want);
    }
}
