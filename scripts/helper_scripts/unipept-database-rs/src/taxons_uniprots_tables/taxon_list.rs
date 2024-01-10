use std::io::BufRead;
use std::path::PathBuf;

use anyhow::{Context, Result};
use bit_vec::BitVec;

use crate::utils::files::open_read;

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
