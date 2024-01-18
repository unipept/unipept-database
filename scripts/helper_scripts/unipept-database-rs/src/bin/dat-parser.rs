use std::io::{BufRead, BufReader, Lines, Stdin};

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

struct SequentialParser {
    lines: Lines<BufReader<Stdin>>,
    data: Vec<String>
}

impl SequentialParser {
    pub fn new(reader: BufReader<Stdin>) -> Self {
        Self {
            lines: reader.lines(),
            data: Vec::new()
        }
    }
}

impl Iterator for SequentialParser {
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
                let entry = UniProtEntry::from(&mut self.data);
                self.data.clear();
                return Some(entry.unwrap());
            }

            self.data.push(line);
        }
    }
}

// Data types
struct UniProtEntry {
    accession_number: String,
    sequence: String
}

impl UniProtEntry {
    pub fn from(data: &mut Vec<String>) -> Result<Self> {
        let mut accession_number = String::new();
        let mut sequence = String::new();
        let mut sequence_index = 0;

        for (idx, line) in data.iter_mut().enumerate() {
            // Accession number
            if line.starts_with("AC") {
                line.drain(..5);
                let (pre, _) = line.split_once(";").with_context(|| format!("Unable to split \"{line}\" on ';'"))?;
                accession_number = pre.to_string();
            }

            // Peptide sequence is always at the end and formatted differently
            // so we handle it as a special case below
            if line.starts_with("SQ") {
                sequence_index = idx + 1;
                break;
            }
        }

        // Construct sequence (which is split over multiple lines)
        for line in data.iter_mut().skip(sequence_index) {
            line.drain(..5);

            sequence.push_str(&line.replace(" ", ""));
        }

        return Ok(Self {
            accession_number,
            sequence
        })
    }

    pub fn write(&self) {
        println!("{}\t{}", self.accession_number, self.sequence)
    }
}