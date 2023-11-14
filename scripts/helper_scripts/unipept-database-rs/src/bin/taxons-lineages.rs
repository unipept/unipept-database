use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use unipept_database::taxons_lineages::taxon_list::TaxonList;

fn main() -> Result<()> {
    let args = Cli::parse();

    let mut tl = TaxonList::from_dumps(&args.names, &args.nodes)
        .context("Failed to parse TaxonList from dumps")?;
    tl.invalidate().context("Failed to validate TaxonList")?;
    tl.write_taxons(&args.taxons)
        .context("Failed to write TaxonList")?;
    tl.write_lineages(&args.lineages)
        .context("Failed to write lineages")?;

    Ok(())
}

#[derive(Parser, Debug)]
struct Cli {
    #[clap(short, long)]
    names: PathBuf,
    #[clap(short, long)]
    nodes: PathBuf,
    #[clap(short, long)]
    taxons: PathBuf,
    #[clap(short, long)]
    lineages: PathBuf,
}
