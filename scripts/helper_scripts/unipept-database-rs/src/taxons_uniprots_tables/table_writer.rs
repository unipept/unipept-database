use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;

use anyhow::{Context, Result};

use crate::taxons_uniprots_tables::models::{Entry};
use crate::utils::files::open_write;

/// Note: this is single-threaded
///       we attempted a parallel version that wrote to all files at the same time,
///       but this didn't achieve any speed increase, so we decided not to go forward with it
pub struct TableWriter {
    uniprot_entries: BufWriter<File>,
    uniprot_count: i64
}

impl TableWriter {
    pub fn new(
        uniprot_entries: &PathBuf
    ) -> Result<Self> {
        Ok(TableWriter {
            uniprot_entries: open_write(uniprot_entries).context("Unable to open output file")?,
            uniprot_count: 0
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

        Ok(())
    }

    // Store the entry info and return the generated id
    fn write_uniprot_entry(&mut self, entry: &Entry) -> Result<i64> {
        self.uniprot_count += 1;

        let accession_number = &entry.accession_number;
        let taxon_id = entry.taxon_id;

        // Summarize the functional annotations as a JSON object that can be written to the output file.
        let summarized_fas = self.summarize_fas(
            &entry.go_references,
            &entry.ec_references,
            &entry.ip_references
        );

        writeln!(
            &mut self.uniprot_entries,
            "{}\t{}\t{}\t{}",
            self.uniprot_count, accession_number, taxon_id, summarized_fas
        )
        .context("Error writing to TSV")?;

        return Ok(self.uniprot_count);
    }

    fn summarize_fas(
        &mut self,
        gos: &Vec<String>,
        ecs: &Vec<String>,
        iprs: &Vec<String>
    ) -> String {
        let go_ids = gos
            .iter();
        let ec_ids = ecs
            .iter()
            .filter(|x| !x.is_empty())
            .map(|x| format!("EC:{}", x));
        let ip_ids = iprs
            .iter()
            .filter(|x| !x.is_empty())
            .map(|x| format!("IPR:{}", x));

        let mut m: HashMap<String, u32> = HashMap::new();

        for go in go_ids {
            if !go.is_empty() {
                *m.entry(go.clone()).or_insert(0) += 1;
            }
        }

        for ec in ec_ids {
            *m.entry(ec.clone()).or_insert(0) += 1;
        }

        for ipr in ip_ids {
            *m.entry(ipr.clone()).or_insert(0) += 1;
        }

        let data = m
            .iter()
            .map(|(key, value)| format!(r#""{key}":{value}"#))
            .collect::<Vec<String>>()
            .join(",");

        return format!(
            "{{{data}}}"
        );
    }
}
