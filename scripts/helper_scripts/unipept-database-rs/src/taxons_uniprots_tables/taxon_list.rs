use crate::taxons_uniprots_tables::models::{Rank, Taxon};
use std::io::BufRead;
use std::path::PathBuf;
use std::str::FromStr;
use anyhow::{Context, Result};

use crate::utils::files::open_read;

pub struct TaxonList {
    entries: Vec<Option<Taxon>>,
}

impl TaxonList {
    pub fn from_file(pb: &PathBuf) -> Result<Self> {
        let mut entries = Vec::new();
        let reader = open_read(pb);

        for line in reader.lines() {
            let line = line.unwrap();
            let spl: Vec<&str> = line.split('\t').collect();
            let id: usize = spl[0].parse().with_context(|| format!("Unable to parse {} as usize", spl[0]))?;
            let parent: usize = spl[3].parse().with_context(|| format!("Unable to parse {} as usize", spl[3]))?;
            let valid = spl[4].trim() == "true";

            let taxon = Taxon::new(
                spl[1].to_string(),
                Rank::from_str(spl[2]).with_context(|| format!("Unable to parse {} into Rank", spl[2]))?,
                parent,
                valid,
            );

            while entries.len() <= id {
                entries.push(None);
            }

            entries[id] = Some(taxon);
        }

        Ok(TaxonList { entries })
    }

    pub fn get(&self, i: usize) -> &Option<Taxon> {
        &self.entries[i]
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

/// Parse a taxons TSV-file into a vector that can be accessed by id
/// The actual content of these Taxons is never used, so we don't try to parse a struct
/// TODO a form of bitvector would be even more efficient
pub fn parse_taxon_file_basic(pb: &PathBuf) -> Result<Vec<bool>> {
    let mut entries = Vec::new();
    let reader = open_read(pb);

    for line in reader.lines() {
        let line = line.unwrap();
        let spl = line
            .split_once('\t').with_context("Unable to split taxon file on tabs")?;
        let id: usize = spl.0.parse().with_context(|| format!("Unable to parse {} as usize", spl.0))?;

        while entries.len() <= id {
            entries.push(false);
        }

        entries[id] = true;
    }

    Ok(entries)
}
