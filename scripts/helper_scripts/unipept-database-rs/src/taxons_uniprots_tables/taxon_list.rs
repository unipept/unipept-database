use crate::taxons_uniprots_tables::models::{Rank, Taxon};
use anyhow::{Context, Result};
use bit_vec::BitVec;
use std::io::BufRead;
use std::path::PathBuf;
use std::str::FromStr;

use crate::utils::files::open_read;

pub struct TaxonList {
    entries: Vec<Option<Taxon>>,
}

impl TaxonList {
    pub fn from_file(pb: &PathBuf) -> Result<Self> {
        let mut entries = Vec::new();
        let reader = open_read(pb).context("Unable to open input file")?;

        for line in reader.lines() {
            let line = line
                .with_context(|| format!("Error reading line from input file {}", pb.display()))?;
            let spl: Vec<&str> = line.split('\t').collect();
            let id: usize = spl[0]
                .parse()
                .with_context(|| format!("Unable to parse {} as usize", spl[0]))?;
            let parent: usize = spl[3]
                .parse()
                .with_context(|| format!("Unable to parse {} as usize", spl[3]))?;
            let valid = spl[4].trim() == "true";

            let taxon = Taxon::new(
                spl[1].to_string(),
                Rank::from_str(spl[2])
                    .with_context(|| format!("Unable to parse {} into Rank", spl[2]))?,
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
pub fn parse_taxon_file_basic(pb: &PathBuf) -> Result<BitVec> {
    let mut entries = BitVec::new();
    let reader = open_read(pb).context("Unable to open taxon input file")?;

    for line in reader.lines() {
        let line = line.context("Error reading line from taxon file")?;
        let spl = line
            .split_once('\t')
            .context("Unable to split taxon file on tabs")?;
        let id: usize = spl
            .0
            .parse()
            .with_context(|| format!("Unable to parse {} as usize", spl.0))?;

        if entries.len() <= id {
            entries.grow(id - entries.len() + 1, false)
        }

        entries.set(id, true);
    }

    Ok(entries)
}
