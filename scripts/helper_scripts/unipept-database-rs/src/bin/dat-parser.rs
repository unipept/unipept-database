use std::io::{BufRead, Lines};

use anyhow::{Context, Result};
use clap::Parser;

use unipept_database::utils::files::open_sin;

fn main() -> Result<()> {
    let args = Cli::parse();
    let reader = open_sin();
    // let (s_raw, r_raw) = bounded::<Vec<String>>(4);
    let parser = SequentialParser::new(reader);
    for entry in parser {
        entry.write(&args.db_type);
    }

    Ok(())
}

#[derive(Parser, Debug)]
struct Cli {
    #[clap(value_enum, short = 't', long, default_value_t = UniprotType::Swissprot)]
    db_type: UniprotType,
}

#[derive(clap::ValueEnum, Clone, Debug)]
enum UniprotType {
    Swissprot,
    Trembl,
}

impl UniprotType {
    pub fn to_str(&self) -> &str {
        match self {
            UniprotType::Swissprot => "swissprot",
            UniprotType::Trembl => "trembl",
        }
    }
}

struct SequentialParser<B: BufRead> {
    lines: Lines<B>,
    data: Vec<String>,
}

impl<B: BufRead> SequentialParser<B> {
    pub fn new(reader: B) -> Self {
        Self {
            lines: reader.lines(),
            data: Vec::new(),
        }
    }
}

impl<B: BufRead> Iterator for SequentialParser<B> {
    type Item = UniProtEntry;

    fn next(&mut self) -> Option<Self::Item> {
        // A loop combined with Lines.next() is an alternative for a for-loop over Lines,
        // as that takes ownership of the Lines variable (which we don't want/can't do)
        loop {
            let line = self.lines.next();
            if line.is_none() {
                return None;
            }

            let line = line?.unwrap();

            if line == "//" {
                let entry = UniProtEntry::from_lines(&mut self.data);
                self.data.clear();
                return Some(entry.unwrap());
            }

            self.data.push(line);
        }
    }
}

// Constants to aid in parsing
const COMMON_PREFIX_LEN: usize = "ID   ".len();

const ORGANISM_RECOMMENDED_NAME_PREFIX_LEN: usize = "DE   RecName: Full=".len();
const ORGANISM_RECOMMENDED_NAME_EC_PREFIX_LEN: usize = "DE            EC=".len();
const ORGANISM_TAXON_ID_PREFIX_LEN: usize = "OX   NCBI_TaxID=".len();
const VERSION_STRING_FULL_PREFIX_LEN: usize = "DT   08-NOV-2023, entry version ".len();

// Data types
struct UniProtEntry {
    accession_number: String,
    name: String,
    sequence: String,
    version: String,
    ec_references: Vec<String>,
    go_references: Vec<String>,
    ip_references: Vec<String>,
    taxon_id: String,
}

impl UniProtEntry {
    pub fn from_lines(data: &mut Vec<String>) -> Result<Self> {
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
        current_index = parse_name(data, current_index, &mut ec_references, &mut name);
        current_index = parse_taxon_id(data, current_index, &mut taxon_id).context("Error parsing taxon id")?;
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

    pub fn write(&self, db_type: &UniprotType) {
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            self.accession_number,
            self.name,
            self.sequence,
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
fn parse_ac_number(data: &mut Vec<String>) -> Result<String> {
    // The AC number is always the second element
    let line = &mut data[1];
    line.drain(..COMMON_PREFIX_LEN);
    let (pre, _) = line.split_once(";").with_context(|| format!("Unable to split \"{line}\" on ';'"))?;
    Ok(pre.to_string())
}

fn parse_version(data: &Vec<String>, target: &mut String) -> usize {
    let mut last_field: usize = 2;

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

fn parse_name(data: &mut Vec<String>, mut idx: usize, ec_references: &mut Vec<String>, target: &mut String) -> usize {
    // Find where the info starts and ends
    while !data[idx].starts_with("DE") {
        idx += 1;
    }

    let mut end_index = idx;

    while data[end_index + 1].starts_with("DE") {
        end_index += 1;
    }

    // If there is a recommended name, use that
    if data[idx].starts_with("DE   RecName") {
        let line = &mut data[idx];
        read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN, target);
    }

    // Sometimes this field includes the EC numbers as well
    for i in (idx + 1)..=end_index {
        if data[i].starts_with("DE            EC=") {
            let line = &mut data[i];
            let mut ec_target = String::new();
            read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_EC_PREFIX_LEN, &mut ec_target);
            ec_references.push(ec_target);
            break;
        }
    }

    // After parsing all the EC numbers, if we already have a name just return
    if !target.is_empty() {
        return end_index + 1;
    }

    end_index + 1
}

fn read_until_metadata(line: &mut String, prefix_len: usize, target: &mut String) {
    line.drain(..prefix_len);

    // The line either contains some metadata, or just ends with a semicolon
    // In the latter case, move the position to the end of the string,
    // so we can pretend it is at a bracket and cut the semicolon out
    let bracket_index = match line.find("{") {
        None => line.len(),
        Some(i) => i
    };
    target.push_str(&(line[..bracket_index - 1]));
}

fn parse_taxon_id(data: &Vec<String>, mut idx: usize, target: &mut String) -> Result<usize> {
    while !data[idx].starts_with("OX   NCBI_TaxID=") {
        idx += 1;
    }

    let line = &data[idx];
    let semicolon = line.find(';').with_context(|| format!("Expected semicolon in taxon id line {line}"))?;
    target.push_str(&(line[ORGANISM_TAXON_ID_PREFIX_LEN..semicolon]));

    while data[idx].starts_with("OX") {
        idx += 1;
    }

    Ok(idx)
}

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