use std::collections::HashSet;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;

use crate::models::{Entry, calculate_entry_digest};
use crate::taxon_list::parse_taxon_file_basic;
use anyhow::{Context, Result};
use bit_vec::BitVec;
use utils::open_write;

pub struct EntryTableWriter {
    taxa: BitVec,
    wrong_ids: HashSet<i32>,
    uniprot_entries: BufWriter<File>,
    uniprot_count: i64,
}

impl EntryTableWriter {
    pub fn new(taxa: &PathBuf, uniprot_entries: &PathBuf) -> Result<Self> {
        Ok(Self {
            taxa: parse_taxon_file_basic(taxa).context("Unable to parse taxonomy file")?,
            wrong_ids: HashSet::new(),
            uniprot_entries: open_write(uniprot_entries).context("Unable to open output file")?,
            uniprot_count: 0,
        })
    }

    pub fn write(&mut self, entry: Entry) -> Result<()> {
        self.write_uniprot_entry(&entry)
            .context("Failed to write entry")?;
        Ok(())
    }

    pub fn write_uniprot_entry(&mut self, entry: &Entry) -> Result<i64> {
        if 0 <= entry.taxon_id
            && entry.taxon_id < self.taxa.len() as i32
            && self.taxa[entry.taxon_id as usize]
        // This indexing is safe due to the line above
        {
            self.uniprot_count += 1;

            let accession_number = &entry.accession_number;
            let version = entry.version.clone();
            let taxon_id = entry.taxon_id;
            let type_ = entry.type_.clone();
            let name = entry.name.clone();
            let sequence = entry.sequence.clone();

            let ec = entry
                .ec_references
                .iter()
                .filter(|x| !x.is_empty())
                .map(|x| format!("EC:{}", x))
                .collect::<Vec<String>>()
                .join(";");
            let go = entry.go_references.join(";");
            let ip = entry
                .ip_references
                .iter()
                .filter(|x| !x.is_empty())
                .map(|x| format!("IPR:{}", x))
                .collect::<Vec<String>>()
                .join(";");

            let mut fa = String::with_capacity(ec.len() + go.len() + ip.len() + 2);
            fa.push_str(&ec);
            fa.push(';');
            fa.push_str(&go);
            fa.push(';');
            fa.push_str(&ip);

            writeln!(
                &mut self.uniprot_entries,
                "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                self.uniprot_count, accession_number, version, taxon_id, type_, name, sequence, fa
            )
            .context("Error writing to TSV")?;

            return Ok(self.uniprot_count);
        } else if !self.wrong_ids.contains(&entry.taxon_id) {
            self.wrong_ids.insert(entry.taxon_id);
        }

        Ok(-1)
    }
}

pub struct PeptideTableWriter {
    peptides: BufWriter<File>,
    peptide_count: i64,
    min_length: usize,
    max_length: usize,
}

impl PeptideTableWriter {
    pub fn new(peptides: &PathBuf, min_length: usize, max_length: usize) -> Result<Self> {
        Ok(Self {
            peptides: open_write(peptides).context("Unable to open output file")?,
            peptide_count: 0,
            min_length,
            max_length,
        })
    }

    pub fn write(&mut self, entry_id: i64, entry: Entry) -> Result<()> {
        let go_ids = entry.go_references.into_iter();
        let ec_ids = entry
            .ec_references
            .iter()
            .filter(|x| !x.is_empty())
            .map(|x| format!("EC:{}", x));
        let ip_ids = entry
            .ip_references
            .iter()
            .filter(|x| !x.is_empty())
            .map(|x| format!("IPR:{}", x));

        let summary = go_ids
            .chain(ec_ids)
            .chain(ip_ids)
            .collect::<Vec<String>>()
            .join(";");

        for sequence in calculate_entry_digest(&entry.sequence, self.min_length, self.max_length) {
            let equated_sequence = sequence
                .iter()
                .map(|&x| if x == b'I' { b'L' } else { x })
                .collect::<Vec<u8>>();

            self.peptide_count += 1;

            writeln!(
                &mut self.peptides,
                "{}\t{}\t{}\t{}\t{}\t{}",
                self.peptide_count,
                String::from_utf8_lossy(&equated_sequence),
                String::from_utf8_lossy(sequence),
                entry_id,
                &summary,
                entry.taxon_id
            )
            .context("Error writing to TSV")?;
        }

        Ok(())
    }
}
