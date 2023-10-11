use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Lines};
use crate::{Cli, models};
use crate::models::Entry;
use crate::utils::open;

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
        let mut reader = open(&cli.taxons);
        let mut map = HashMap::new();

        let mut line = String::new();
        reader.read_line(&mut line).expect("unable to read header line");

        let spl = line.split("\t").map(|x| x.trim());

        for (i, l) in spl.enumerate() {
            map.insert(l.to_string(), i);
        }

        TabParser {
            lines: reader.lines(),
            header_map: map,
            min_length: cli.peptide_min,
            max_length: cli.peptide_max,
            verbose: cli.verbose,
        }
    }
}

impl Iterator for TabParser {
    type Item = models::Entry;

    fn next(&mut self) -> Option<Self::Item> {
        let line = self.lines.next()?.unwrap();
        let fields: Vec<&str> = line.trim().split("\t").collect();

        let entry = Entry::new(
            self.min_length,
            self.max_length,
            fields[self.header_map["Status"]].trim().to_string(),
            fields[self.header_map["Entry"]].trim().to_string(),
            fields[self.header_map["Sequence"]].trim().to_string(),
            fields[self.header_map["Protein names"]].trim().to_string(),
            fields[self.header_map["Version (entry)"]].trim().to_string(),
            fields[self.header_map["Organism ID"]].trim().to_string(),
        );

        // TODO vectors

        Some(entry)
    }
}