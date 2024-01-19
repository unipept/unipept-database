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
    db_type: UniprotType
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
const VERSION_STRING_FULL_PREFIX_LEN: usize = "DT   08-NOV-2023, entry version ".len();

// Data types
struct UniProtEntry {
    accession_number: String,
    sequence: String,
    version: String,
}

impl UniProtEntry {
    pub fn from_lines(data: &mut Vec<String>) -> Result<Self> {
        let mut current_index: usize;
        let accession_number: String;
        let mut version = String::new();
        let mut sequence = String::new();

        accession_number = parse_ac_number(data).context("Error getting accession number")?;
        current_index = parse_version(data, &mut version);
        parse_sequence(data, current_index, &mut sequence);

        return Ok(Self {
            accession_number,
            sequence,
            version,
        });
    }

    pub fn write(&self, db_type: &UniprotType) {
        println!("{}\t{}\t{}\t{}", self.accession_number, self.sequence, self.version, db_type.to_str())
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

fn parse_version(data: &mut Vec<String>, target: &mut String) -> usize {
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