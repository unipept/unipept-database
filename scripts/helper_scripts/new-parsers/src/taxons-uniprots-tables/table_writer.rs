use std::collections::HashSet;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::time::Instant;

use crate::Cli;
use crate::models::Entry;
use crate::taxon_list::TaxonList;
use crate::utils::open_write;

pub struct TableWriter {
    taxons: TaxonList,
    wrong_ids: HashSet<u32>,
    peptides: BufWriter<File>,
    uniprot_entries: BufWriter<File>,
    go_cross_references: BufWriter<File>,
    ec_cross_references: BufWriter<File>,
    ip_cross_references: BufWriter<File>,

    peptide_count: i64,
    uniprot_count: i64,
    go_count: i64,
    ec_count: i64,
    ip_count: i64,
}

impl TableWriter {
    pub fn new(cli: &Cli) -> Self {
        TableWriter {
            taxons: TaxonList::from_file(&cli.taxons),
            wrong_ids: HashSet::new(),
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
    pub fn store(&mut self, mut entry: Entry) {
        let id = self.add_uniprot_entry(&entry);

        // Failed to add entry
        if id == -1 { return; }

        let digest = entry.digest();
        let go_ids = entry.go_references.into_iter();
        let ec_ids = entry.ec_references.iter().filter(|x| !x.is_empty()).map(|x| format!("EC:{}", x)).into_iter();
        let ip_ids = entry.ip_references.iter().filter(|x| !x.is_empty()).map(|x| format!("IPR:{}", x)).into_iter();

        let summary = go_ids.chain(ec_ids).chain(ip_ids).collect::<Vec<String>>().join(";");

        for sequence in digest {
            self.add_peptide(sequence.replace("I", "L"), id, sequence, summary.clone());
        }
    }

    // Get the MySQL-compatible representation of a string
    // More specifically, represent empty strings as \\N
    fn string_rep(&self, s: String) -> String {
        if s.is_empty() {
            "\\N".to_string()
        } else {
            s
        }
    }

    fn add_peptide(&mut self, sequence: String, id: i64, original_sequence: String, annotations: String) {
        self.peptide_count += 1;

        let unified_sequence = self.string_rep(sequence);
        let original_sequence = self.string_rep(original_sequence);
        let annotations = self.string_rep(annotations);

        if let Err(e) = write!(
            &mut self.peptides,
            "{}\t{}\t{}\t{}\t{}",
            self.peptide_count,
            unified_sequence, original_sequence,
            id.to_string(), annotations
        ) {
            eprintln!("{}\tError writing to CSV.\n{:?}", Instant::now().elapsed().as_millis(), e);
        }
    }

    // Store the entry info and return the generated id
    fn add_uniprot_entry(&mut self, entry: &Entry) -> i64 {
        if 0 <= entry.taxon_id && entry.taxon_id < self.taxons.len() as u32 && self.taxons.get(entry.taxon_id as usize).is_some() {
            self.uniprot_count += 1;

            let accession_number = self.string_rep(entry.accession_number.clone());
            let version = self.string_rep(entry.version.clone());
            let taxon_id = self.string_rep(entry.taxon_id.to_string());
            let type_ = self.string_rep(entry.type_.clone());
            let name = self.string_rep(entry.name.clone());
            let sequence = self.string_rep(entry.sequence.clone());


            if let Err(e) = write!(
                &mut self.uniprot_entries,
                "{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                self.uniprot_count, accession_number,
                version, taxon_id,
                type_, name,
                sequence
            ) {
                eprintln!("{}\tError writing to CSV.\n{:?}", Instant::now().elapsed().as_millis(), e);
            } else {
                return self.uniprot_count;
            }
        } else {
            if !self.wrong_ids.contains(&entry.taxon_id) {
                self.wrong_ids.insert(entry.taxon_id);
                eprintln!(
                    "{}\t{} added to the list of {} invalid taxonIds.",
                    Instant::now().elapsed().as_millis(),
                    entry.taxon_id,
                    self.wrong_ids.len()
                );
            }
        }

        -1
    }
}