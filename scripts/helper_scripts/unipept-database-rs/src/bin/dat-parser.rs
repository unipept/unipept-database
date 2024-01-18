use std::io::{BufRead, Lines};

use anyhow::{Context, Result};

use unipept_database::utils::files::open_sin;

fn main() -> Result<()> {
    let reader = open_sin();
    // let (s_raw, r_raw) = bounded::<Vec<String>>(4);
    let parser = SequentialParser::new(reader);
    for entry in parser {
        entry.write();
    }

    Ok(())
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
const VERSION_STRING_DATE_PREFIX_LEN: usize = "DT   08-NOV-2023, ".len();
const VERSION_STRING_ENTRY_VERSION_LEN: usize = "entry version".len();
const VERSION_STRING_FULL_PREFIX_LEN: usize = "DT   08-NOV-2023, entry version ".len();

// Data types
struct UniProtEntry {
    accession_number: String,
    sequence: String,
    version: String,
}

impl UniProtEntry {
    pub fn from_lines(data: &mut Vec<String>) -> Result<Self> {
        let mut accession_number = String::new();
        let mut sequence = String::new();
        let mut sequence_index = 0;
        let mut version = String::new();
        let mut version_index = 0;

        for (idx, line) in data.iter_mut().enumerate() {
            // Accession number
            if line.starts_with("AC") {
                line.drain(..5);
                let (pre, _) = line.split_once(";").with_context(|| format!("Unable to split \"{line}\" on ';'"))?;
                accession_number = pre.to_string();
            }

            // One of the date fields contains the entry version
            // and is always in the format "DT   DD-MMM-YYYY, entry version VERSION."
            else if line.starts_with("DT") && version_index == 0 {
                if line.len() <= VERSION_STRING_DATE_PREFIX_LEN + VERSION_STRING_ENTRY_VERSION_LEN {
                    continue;
                }

                if &line[VERSION_STRING_DATE_PREFIX_LEN..VERSION_STRING_DATE_PREFIX_LEN + VERSION_STRING_ENTRY_VERSION_LEN] == "entry version" {
                    version_index = idx;
                }
            }

            // Peptide sequence is always at the end and formatted differently
            // so we handle it as a special case below
            else if line.starts_with("SQ") {
                sequence_index = idx + 1;
                break;
            }
        }

        // Get entry version (has prefix of constant length and ends with a dot)
        let version_end = data[version_index].len() - 1;
        version.push_str(&(data[version_index][VERSION_STRING_FULL_PREFIX_LEN..version_end]));

        // Construct sequence (which is split over multiple lines)
        for line in data.iter_mut().skip(sequence_index) {
            line.drain(..5);

            sequence.push_str(&line.replace(" ", ""));
        }

        return Ok(Self {
            accession_number,
            sequence,
            version,
        });
    }

    pub fn write(&self) {
        println!("{}\t{}\t{}", self.accession_number, self.sequence, self.version)
    }
}