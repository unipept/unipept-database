use std::collections::HashSet;
use std::fs::File;
use std::io::BufWriter;

use crate::Cli;
use crate::models::Entry;
use crate::utils::open_write;

pub struct TableWriter {
    omit: HashSet<u32>,
    peptides: BufWriter<File>,
    uniprot_entries: BufWriter<File>,
    go_cross_references: BufWriter<File>,
    ec_cross_references: BufWriter<File>,
    ip_cross_references: BufWriter<File>,

    peptide_count: u64,
    uniprot_count: u64,
    go_count: u64,
    ec_count: u64,
    ip_count: u64,
}

impl TableWriter {
    pub fn new(cli: &Cli) -> Self {
        TableWriter {
            omit: HashSet::new(),
            peptides: open_write(&cli.peptides),
            uniprot_entries: open_write(&cli.uniprot_entries),
            go_cross_references: open_write(&cli.go),
            ec_cross_references: open_write(&cli.ec),
            ip_cross_references: open_write(&cli.interpro),

            peptide_count: 0,
            uniprot_count: 0,
            go_count: 0,
            ec_count: 0,
            ip_count: 0,
        }
    }

    // Store a complete entry in the database
    pub fn store(&self, entry: Entry) {}

    // Store
    fn add_uniprot_entry(&self, entry: Entry) -> u64 {
        todo!()
    }
}