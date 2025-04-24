use anyhow::{Context, anyhow};
use std::collections::HashSet;
use tables_generator::models::Entry;

// Constants to aid in parsing
const COMMON_PREFIX_LEN: usize = "ID   ".len();
const DATE_LENGTH: usize = "DD-MMM-YYYY".len();

const DT_PREFIX_INTEGRATED_LENGTH: usize =
    COMMON_PREFIX_LEN + DATE_LENGTH + ", integrated into ".len();
const DT_PREFIX_VERSION_LENGTH: usize = COMMON_PREFIX_LEN + DATE_LENGTH + ", entry version ".len();

const DE_PREFIX_NAME_LENGTH: usize = "RecName: Full=".len();
const DE_PREFIX_EC_LENGTH: usize = "EC=".len();

const OX_PREFIX_NCBI_LENGTH: usize = "OX   NCBI_TaxID=".len();

#[derive(Default)]
pub struct DatabaseReferences {
    go_references: Vec<String>,
    ipr_references: Vec<String>,
    proteome_references: Vec<String>,
}

/// The minimal data we want from an entry out of the UniProtKB datasets
#[derive(Debug)]
pub struct UniProtDATEntry {
    accession_number: String,
    name: String,
    sequence: String,
    version: String,
    database_type: String,
    ec_references: Vec<String>,
    go_references: Vec<String>,
    ip_references: Vec<String>,
    proteome_references: Vec<String>,
    taxon_id: String,
}

impl From<UniProtDATEntry> for Entry {
    fn from(entry: UniProtDATEntry) -> Self {
        Entry::new(
            entry.database_type,
            entry.accession_number,
            entry.sequence,
            entry.name,
            entry.version,
            entry.taxon_id,
            entry.ec_references,
            entry.go_references,
            entry.ip_references,
            entry.proteome_references,
        )
        .unwrap()
    }
}

impl UniProtDATEntry {
    /// Parse an entry out of the lines of a DAT file
    pub fn from_lines(data: &[String]) -> anyhow::Result<Self> {
        let mut data_cursor: usize = 0;

        // Skip the ID (identifier) field
        skip_until_field(data, &mut data_cursor, "AC");

        // Parse the AC (accession number) field
        let accession_number = parse_accession_number_field(data, &mut data_cursor)
            .context("Error parsing the accession number")?;

        // Skip other AC fields. We only store the first (newest) accession number
        skip_until_field(data, &mut data_cursor, "DT");

        // Parse the DT (date) fields
        let (database_type, version) = parse_date_fields(data, &mut data_cursor)
            .context("Error parsing the date information")?;

        // Parse the DE (description) fields
        let (name, ec_references) = parse_description_field(data, &mut data_cursor);

        // Skip the GN (gene name), OS (organism), and OC (organism classification) fields
        skip_until_field(data, &mut data_cursor, "OX");

        // Parse the OX (taxonomy cross-reference) field
        let taxon_id = parse_taxonomy_reference(data, &mut data_cursor);

        // Skip the OH (organism host), all Rx (references) and CC (comments and notes) fields
        let db_references_found = skip_until_optional_field(data, &mut data_cursor, "DR");

        // Parse the DR (database cross-reference) fields
        let db_references = if db_references_found {
            parse_db_references(data, &mut data_cursor)
        } else {
            DatabaseReferences::default()
        };

        // Skip the PE (protein existence), KW (keywords) and FT (feature table data) fields
        skip_until_field(data, &mut data_cursor, "SQ");

        // Parse the (SQ) sequence field
        let sequence = parse_sequence(data, &mut data_cursor);

        Ok(Self {
            accession_number,
            name,
            sequence,
            version,
            database_type,
            ec_references: ec_references.into_iter().collect(),
            go_references: db_references.go_references,
            ip_references: db_references.ipr_references,
            proteome_references: db_references.proteome_references,
            taxon_id,
        })
    }

    /// Write an entry to stdout
    pub fn write(&self) {
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
            self.database_type,
            self.taxon_id
        )
    }
}

// Functions to parse an Entry out of a Vec<String>

fn skip_until_field(data: &[String], data_cursor: &mut usize, field: &str) {
    let mut current_line = *data_cursor;
    while !data[current_line].starts_with(field) {
        current_line += 1;
    }
    *data_cursor = current_line;
}

fn skip_until_optional_field(data: &[String], data_cursor: &mut usize, field: &str) -> bool {
    let mut current_line = *data_cursor;
    while !data[current_line].starts_with(field) {
        current_line += 1;

        if current_line >= data.len() {
            return false;
        }
    }

    *data_cursor = current_line;

    true
}

/// Find the first AC number
fn parse_accession_number_field(
    data: &[String],
    data_cursor: &mut usize,
) -> anyhow::Result<String> {
    // Parse the string of accession numbers. Skip the AC prefix
    let accession_numbers = &data[*data_cursor][COMMON_PREFIX_LEN..];
    let (first_accession, _) = accession_numbers
        .split_once(';')
        .with_context(|| format!("Unable to split \"{accession_numbers}\" on ';'"))?;

    // Remove this AC line from the data
    *data_cursor += 1;

    Ok(first_accession.to_string())
}

/// Find the version of this entry
fn parse_date_fields(data: &[String], data_cursor: &mut usize) -> anyhow::Result<(String, String)> {
    // Extract the database type from the first line
    let first_line = &data[*data_cursor][DT_PREFIX_INTEGRATED_LENGTH..];
    let database_type: String = match first_line {
        "UniProtKB/Swiss-Prot." => Ok("swissprot".to_string()),
        "UniProtKB/TrEMBL." => Ok("trembl".to_string()),
        _ => Err(anyhow!("Error: Unknown database type".to_string())),
    }?;

    // Get entry version on the third line (has prefix of constant length and ends with a dot)
    let version_with_dot = &data[*data_cursor + 2][DT_PREFIX_VERSION_LENGTH..];
    let version = version_with_dot[..version_with_dot.len() - 1].to_string();

    // Move the cursor to the next section
    *data_cursor += 3;

    Ok((database_type, version))
}

/// Parse the name and EC numbers of an entry out of all available DE fields
/// In order of preference:
/// - Last recommended name of protein components
/// - Last recommended name of protein domains
/// - Recommended name of protein itself
/// - Last submitted name of protein components
/// - Last submitted name of protein domains
/// - Submitted name of protein itself
fn parse_description_field(data: &[String], data_cursor: &mut usize) -> (String, HashSet<String>) {
    let mut name = String::new();
    let mut ec_references = HashSet::new();

    // Track all names in order of preference
    let mut name_indices: [usize; 6] = [usize::MAX; 6];
    const LAST_COMPONENT_RECOMMENDED_IDX: usize = 0;
    const LAST_DOMAIN_RECOMMENDED_IDX: usize = 1;
    const LAST_PROTEIN_RECOMMENDED_IDX: usize = 2;
    const LAST_COMPONENT_SUBMITTED_IDX: usize = 3;
    const LAST_DOMAIN_SUBMITTED_IDX: usize = 4;
    const LAST_PROTEIN_SUBMITTED_IDX: usize = 5;

    // Keep track of which block we are currently in
    // Order in DAT file is always protein -> components -> domain
    let mut inside_domain = false;
    let mut inside_component = false;

    while data[*data_cursor].starts_with("DE") {
        let line = data[*data_cursor][COMMON_PREFIX_LEN..].trim_start();

        // Marks the start of a Component
        if line == "Contains:" {
            inside_component = true;
            *data_cursor += 1;
            continue;
        }

        // Marks the start of a Domain
        if line == "Includes:" {
            inside_domain = true;
            *data_cursor += 1;
            continue;
        }

        // Keep track of the last recommended or submitted name
        if line.starts_with("RecName: Full=") || line.starts_with("SubName: Full=") {
            let index = match (
                line.starts_with("RecName: Full="),
                inside_domain,
                inside_component,
            ) {
                (true, true, _) => LAST_DOMAIN_RECOMMENDED_IDX,
                (true, _, true) => LAST_COMPONENT_RECOMMENDED_IDX,
                (true, _, _) => LAST_PROTEIN_RECOMMENDED_IDX,
                (false, true, _) => LAST_DOMAIN_SUBMITTED_IDX,
                (false, _, true) => LAST_COMPONENT_SUBMITTED_IDX,
                (false, _, _) => LAST_PROTEIN_SUBMITTED_IDX,
            };
            name_indices[index] = *data_cursor;
        }
        // Find EC numbers
        else if line.starts_with("EC=") {
            let ec_target = read_until_metadata(&line[DE_PREFIX_EC_LENGTH..]);
            if !ec_references.contains(&ec_target) {
                ec_references.insert(ec_target);
            }
        }

        *data_cursor += 1;
    }

    // Choose a name from the ones we encountered
    // Use the first name that we managed to find, in order
    for name_index in name_indices {
        if name_index != usize::MAX {
            let line = data[name_index][COMMON_PREFIX_LEN..].trim_start();
            name = read_until_metadata(&line[DE_PREFIX_NAME_LENGTH..]);
            return (name, ec_references);
        }
    }

    (name, ec_references)
}

/// Find the first NCBI_TaxID of this entry
fn parse_taxonomy_reference(data: &[String], data_cursor: &mut usize) -> String {
    let line = &data[*data_cursor][OX_PREFIX_NCBI_LENGTH..];

    // Move the cursor to the next section
    *data_cursor += 1;

    read_until_metadata(line)
}

/// Parse GO and InterPro DB references
fn parse_db_references(data: &[String], data_cursor: &mut usize) -> DatabaseReferences {
    let mut go_references = Vec::new();
    let mut ipr_references = Vec::new();
    let mut proteome_references = Vec::new();

    // Parse all references
    while data[*data_cursor].starts_with("DR") {
        let line = &data[*data_cursor][COMMON_PREFIX_LEN..];

        parse_db_reference(
            line,
            &mut go_references,
            &mut ipr_references,
            &mut proteome_references,
        );

        *data_cursor += 1;
    }

    DatabaseReferences {
        go_references,
        ipr_references,
        proteome_references,
    }
}

/// Parse a single GO or InterPro DB reference
fn parse_db_reference(
    line: &str,
    go_references: &mut Vec<String>,
    ipr_references: &mut Vec<String>,
    proteome_references: &mut Vec<String>,
) {
    if line.starts_with("GO;") {
        go_references.push(line[4..14].to_string());
    } else if line.starts_with("InterPro;") {
        ipr_references.push(line[10..19].to_string());
    } else if line.starts_with("Proteomes;") {
        proteome_references.push(line[11..22].to_string());
    }
}

/// Parse the peptide sequence for this entry
fn parse_sequence(data: &[String], data_cursor: &mut usize) -> String {
    // First line of the sequence contains some metadata we don't care for
    *data_cursor += 1;

    let mut sequence = String::new();

    // Combine all remaining lines
    for line in data.iter().skip(*data_cursor) {
        let line = &line[COMMON_PREFIX_LEN..];
        sequence.push_str(&line.replace(' ', ""));
    }

    sequence
}

/// Read a line until additional metadata starts
/// Some lines end with {blocks between curly brackets} that we don't care for.
fn read_until_metadata(line: &str) -> String {
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
        let got = parse_accession_number_field(&mut lines, &mut 1).unwrap();

        assert_eq!(got, want);
    }

    #[test]
    fn test_parse_version() {
        let want_type = "swissprot";
        let want_version = "44";
        let mut lines = get_example_entry();
        let (got_type, got_version) = parse_date_fields(&mut lines, &mut 2).unwrap();

        assert_eq!(got_type, want_type);
        assert_eq!(got_version, want_version);
    }

    #[test]
    fn test_parse_description_field() {
        let want_name = "Putative transcription factor 001R";
        let mut lines = get_example_entry();
        let (got_name, got_ec) = parse_description_field(&mut lines, &mut 5);

        assert_eq!(got_name, want_name);
    }

    #[test]
    fn test_parse_taxon_id() {
        let want = "654924";
        let mut lines = get_example_entry();
        let got = parse_taxonomy_reference(&mut lines, &mut 10);

        assert_eq!(got, want);
    }

    #[test]
    fn test_parse_db_references() {
        let want_go = vec![String::from("GO:0046782"), String::from("GO:0016743")];
        let want_ipr = vec![String::from("IPR007031"), String::from("IPR000308")];
        let want_proteome = vec![String::from("UP000008770")];
        let mut lines = get_example_entry();
        let got_references = parse_db_references(&mut lines, &mut 27);

        assert_eq!(got_references.go_references, want_go);
        assert_eq!(got_references.ipr_references, want_ipr);
        assert_eq!(got_references.proteome_references, want_proteome);
    }

    #[test]
    fn test_parse_db_reference_go() {
        let want = vec![String::from("GO:0046782")];
        let mut line =
            String::from("GO; GO:0046782; P:regulation of viral transcription; IEA:InterPro.");
        let mut target = Vec::new();
        let mut _dummy = Vec::new();
        let mut _dummy2 = Vec::new();
        parse_db_reference(&mut line, &mut target, &mut _dummy, &mut _dummy2);

        assert_eq!(target, want);
        assert!(_dummy.is_empty());
        assert!(_dummy2.is_empty());
    }

    #[test]
    fn test_parse_db_reference_ip() {
        let want = vec![String::from("IPR007031")];
        let mut line = String::from("InterPro; IPR007031; Poxvirus_VLTF3.");
        let mut target = Vec::new();
        let mut _dummy = Vec::new();
        let mut _dummy2 = Vec::new();
        parse_db_reference(&mut line, &mut _dummy, &mut target, &mut _dummy2);

        assert_eq!(target, want);
        assert!(_dummy.is_empty());
        assert!(_dummy2.is_empty());
    }

    #[test]
    fn test_parse_db_reference_proteome() {
        let want = vec![String::from("UP000008770")];
        let mut line = String::from("Proteomes; UP000008770; Segment.");
        let mut target = Vec::new();
        let mut _dummy = Vec::new();
        let mut _dummy2 = Vec::new();
        parse_db_reference(&mut line, &mut _dummy, &mut _dummy2, &mut target);

        assert_eq!(target, want);
        assert!(_dummy.is_empty());
        assert!(_dummy2.is_empty());
    }

    #[test]
    fn test_parse_sequence() {
        let want = "MAFSAEDVLKEYDRRRRMEALLLSLYYPNDRKLLDYKEWSPPRVQVECPKAPVEWNNPPSEKGLIVGHFSGIKYKGEKAQASEVDVNKMCCWVSKFKDAMRRYQGIQTCKIPGKVLSDLD";
        let mut lines = get_example_entry();
        let got = parse_sequence(&mut lines, &mut 43);
        assert_eq!(got, want);
    }

    // #[test]
    // fn test_read_until_metadata() {
    //     let want = "Alanine racemase";
    //     let mut line = String::from(format!(
    //         "RecName: Full={want} {{ECO:0000255|HAMAP-Rule:MF_01201}};"
    //     ));
    //     let got = read_until_metadata(&mut line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN);
    //     assert_eq!(got, want);
    // }
    //
    // #[test]
    // fn test_read_until_metadata_with_bracket() {
    //     let want = "Alanine racemase{text between brackets}";
    //     let mut line = String::from(format!(
    //         "RecName: Full={want} {{ECO:0000255|HAMAP-Rule:MF_01201}};"
    //     ));
    //     let target = read_until_metadata(&mut line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN);
    //     assert_eq!(target, want);
    // }
    //
    // #[test]
    // fn test_read_until_metadata_none() {
    //     let want = "Recommended Name";
    //     let mut line = String::from(format!("RecName: Full={want};"));
    //     let target = read_until_metadata(&mut line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN);
    //     assert_eq!(target, want);
    // }

    #[test]
    fn test_parse_entry() {
        let mut lines = get_example_entry();
        let got = UniProtDATEntry::from_lines(&mut lines).unwrap();

        assert_eq!(got.accession_number, "P9WPY2");
        assert_eq!(got.name, "Putative transcription factor 001R");
        assert_eq!(got.version, "44");
        assert_eq!(got.taxon_id, "654924");
        assert_eq!(got.ec_references.len(), 0);
        assert_eq!(
            got.go_references,
            vec![String::from("GO:0046782"), String::from("GO:0016743")]
        );
        assert_eq!(
            got.ip_references,
            vec![String::from("IPR007031"), String::from("IPR000308")]
        );
        assert_eq!(
            got.sequence,
            "MAFSAEDVLKEYDRRRRMEALLLSLYYPNDRKLLDYKEWSPPRVQVECPKAPVEWNNPPSEKGLIVGHFSGIKYKGEKAQASEVDVNKMCCWVSKFKDAMRRYQGIQTCKIPGKVLSDLD"
        )
    }
}
