use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Lines};

use crate::Cli;
use crate::models::Entry;
use crate::utils::open_read;

pub struct TabParser {
    lines: Lines<BufReader<File>>,
    header_map: HashMap<String, usize>,
    min_length: u32,
    max_length: u32,
    verbose: bool,
}

impl TabParser {
    pub fn new(cli: &Cli) -> Self {
        // First read the header line
        let mut reader = open_read(&cli.taxons);
        let mut map = HashMap::new();
        let mut lines = reader.lines();

        let line = match lines.next() {
            None => {
                eprintln!("unable to read header line");
                std::process::exit(1)
            },
            Some(s) => s.expect("unable to read header line")
        };

        for (i, l) in line.split("\t").enumerate() {
            map.insert(l.trim().to_string(), i);
        }

        TabParser {
            lines,
            header_map: map,
            min_length: cli.peptide_min,
            max_length: cli.peptide_max,
            verbose: cli.verbose,
        }
    }
}

impl Iterator for TabParser {
    type Item = Entry;

    fn next(&mut self) -> Option<Self::Item> {
        let line = self.lines.next()?.unwrap();
        let fields: Vec<&str> = line.trim().split("\t").collect();

        let mut entry = Entry::new(
            self.min_length,
            self.max_length,
            fields[self.header_map["Status"]].trim().to_string(),
            fields[self.header_map["Entry"]].trim().to_string(),
            fields[self.header_map["Sequence"]].trim().to_string(),
            fields[self.header_map["Protein names"]].trim().to_string(),
            fields[self.header_map["Version (entry)"]].trim().to_string(),
            fields[self.header_map["Organism ID"]].trim().to_string(),
        );

        for ec in fields[self.header_map["EC number"]].split(";") {
            entry.ec_references.push(ec.trim().to_string());
        }

        for go in fields[self.header_map["Gene ontology IDs"]].split(";") {
            entry.go_references.push(go.trim().to_string());
        }

        for ip in fields[self.header_map["Cross-reference (InterPro)"]].split(";") {
            entry.ip_references.push(ip.trim().to_string());
        }

        Some(entry)
    }
}