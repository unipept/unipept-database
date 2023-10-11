use std::collections::HashSet;
use std::fs::File;
use std::io::BufReader;

use crate::Cli;
use crate::models::Entry;
use crate::utils::open;

pub struct TableWriter {
    omit: HashSet<u32>,
    peptides: BufReader<File>,
    uniprot_entries: BufReader<File>,
    go_cross_references: BufReader<File>,
    ec_cross_references: BufReader<File>,
    ip_cross_references: BufReader<File>,
}

impl TableWriter {
    pub fn new(cli: &Cli) -> Self {
        TableWriter {
            omit: HashSet::new(),
            peptides: open(&cli.peptides),
            uniprot_entries: open(&cli.uniprot_entries),
            go_cross_references: open(&cli.go),
            ec_cross_references: open(&cli.ec),
            ip_cross_references: open(&cli.interpro)
        }
    }

    pub fn store(&self, entry: Entry) {

    }
}