use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use crate::taxon_list::TaxonList;

mod taxon;
mod taxon_list;

fn main() -> Result<()> {
    let args = Cli::parse();

    let mut taxon_list = TaxonList::from_dumps(&args.names, &args.nodes)
        .context("Failed to parse TaxonList from dumps")?;
    taxon_list.invalidate().context("Failed to validate TaxonList")?;
    taxon_list.write_taxons(&args.taxa)
        .context("Failed to write TaxonList")?;
    taxon_list.write_lineages(&args.lineages)
        .context("Failed to write lineages")?;

    Ok(())
}

#[derive(Parser, Debug)]
struct Cli {
    /// Path to the names.dmp file
    #[clap(long)]
    names: PathBuf,

    /// Path to the nodes.dmp file
    #[clap(long)]
    nodes: PathBuf,

    /// Path to the output taxa file
    #[clap(long)]
    taxa: PathBuf,

    /// Path to the output lineages file
    #[clap(long)]
    lineages: PathBuf
}
