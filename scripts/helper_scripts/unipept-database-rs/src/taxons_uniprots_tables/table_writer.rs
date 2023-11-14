use std::collections::HashSet;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;

use anyhow::{Context, Result};
use bit_vec::BitVec;

use crate::taxons_uniprots_tables::models::{calculate_entry_digest, Entry};
use crate::taxons_uniprots_tables::taxon_list::parse_taxon_file_basic;
use crate::taxons_uniprots_tables::utils::now_str;
use crate::utils::files::open_write;

/// Note: this is single-threaded
///       we attempted a parallel version that wrote to all files at the same time,
///       but this didn't achieve any speed increase, so we decided not to go forward with it
pub struct TableWriter {
    taxons: BitVec,
    wrong_ids: HashSet<i32>,
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
    pub fn new(
        taxons: &PathBuf,
        peptides: &PathBuf,
        uniprot_entries: &PathBuf,
        go_references: &PathBuf,
        ec_references: &PathBuf,
        interpro_references: &PathBuf,
    ) -> Result<Self> {
        Ok(TableWriter {
            taxons: parse_taxon_file_basic(taxons).context("Unable to parse taxonomy file")?,
            wrong_ids: HashSet::new(),
            peptides: open_write(peptides).context("Unable to open output file")?,
            uniprot_entries: open_write(uniprot_entries).context("Unable to open output file")?,
            go_cross_references: open_write(go_references).context("Unable to open output file")?,
            ec_cross_references: open_write(ec_references).context("Unable to open output file")?,
            ip_cross_references: open_write(interpro_references)
                .context("Unable to open output file")?,

            peptide_count: 0,
            uniprot_count: 0,
            go_count: 0,
            ec_count: 0,
            ip_count: 0,
        })
    }

    // Store a complete entry in the database
    pub fn store(&mut self, entry: Entry) -> Result<()> {
        let id = self
            .write_uniprot_entry(&entry)
            .context("Failed to write Uniprot entry")?;

        // Failed to add entry
        if id == -1 {
            return Ok(());
        }

        for r in &entry.go_references {
            self.write_go_ref(r, id).context("Error writing GO ref")?;
        }

        for r in &entry.ec_references {
            self.write_ec_ref(r, id).context("Error writing EC ref")?;
        }

        for r in &entry.ip_references {
            self.write_ip_ref(r, id)
                .context("Error writing Interpro ref")?;
        }

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

        for sequence in calculate_entry_digest(
            &entry.sequence,
            entry.min_length as usize,
            entry.max_length as usize,
        ) {
            self.write_peptide(
                sequence
                    .iter()
                    .map(|&x| if x == b'I' { b'L' } else { x })
                    .collect(),
                id,
                sequence,
                &summary,
            )
            .context("Failed to write peptide")?;
        }

        Ok(())
    }

    fn write_peptide(
        &mut self,
        sequence: Vec<u8>,
        id: i64,
        original_sequence: &[u8],
        annotations: &String,
    ) -> Result<()> {
        self.peptide_count += 1;

        writeln!(
            &mut self.peptides,
            "{}\t{}\t{}\t{}\t{}",
            self.peptide_count,
            String::from_utf8(sequence)?,
            String::from_utf8_lossy(original_sequence),
            id,
            annotations
        )
        .context("Error writing to TSV")?;

        Ok(())
    }

    // Store the entry info and return the generated id
    fn write_uniprot_entry(&mut self, entry: &Entry) -> Result<i64> {
        if 0 <= entry.taxon_id
            && entry.taxon_id < self.taxons.len() as i32
            && self.taxons[entry.taxon_id as usize]
        // This indexing is safe due to the line above
        {
            self.uniprot_count += 1;

            let accession_number = &entry.accession_number;
            let version = entry.version.clone();
            let taxon_id = entry.taxon_id;
            let type_ = entry.type_.clone();
            let name = entry.name.clone();
            let sequence = entry.sequence.clone();

            writeln!(
                &mut self.uniprot_entries,
                "{}\t{}\t{}\t{}\t{}\t{}\t{}",
                self.uniprot_count, accession_number, version, taxon_id, type_, name, sequence
            )
            .context("Error writing to TSV")?;

            return Ok(self.uniprot_count);
        } else if !self.wrong_ids.contains(&entry.taxon_id) {
            self.wrong_ids.insert(entry.taxon_id);
            eprintln!(
                "[{}]\t{} added to the list of {} invalid taxonIds",
                now_str(),
                entry.taxon_id,
                self.wrong_ids.len()
            );
        }

        Ok(-1)
    }

    fn write_go_ref(&mut self, ref_id: &String, uniprot_entry_id: i64) -> Result<()> {
        self.go_count += 1;

        writeln!(
            &mut self.go_cross_references,
            "{}\t{}\t{}",
            self.go_count, uniprot_entry_id, ref_id
        )
        .context("Error writing to TSV")?;

        Ok(())
    }

    fn write_ec_ref(&mut self, ref_id: &String, uniprot_entry_id: i64) -> Result<()> {
        self.ec_count += 1;

        writeln!(
            &mut self.ec_cross_references,
            "{}\t{}\t{}",
            self.ec_count, uniprot_entry_id, ref_id
        )
        .context("Error writing to TSV")?;

        Ok(())
    }

    fn write_ip_ref(&mut self, ref_id: &String, uniprot_entry_id: i64) -> Result<()> {
        self.ip_count += 1;

        writeln!(
            &mut self.ip_cross_references,
            "{}\t{}\t{}",
            self.ip_count, uniprot_entry_id, ref_id,
        )
        .context("Error writing to TSV")?;

        Ok(())
    }
}
