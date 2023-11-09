use std::path::PathBuf;
use clap::Parser;
use unipept_database::taxons_lineages::taxon_list::TaxonList;
use anyhow::{Context, Result};

fn main() -> Result<()>{
    let args = Cli::parse();

    let mut tl = TaxonList::from_dumps(&args.names, &args.nodes).context("Failed to parse TaxonList from dumps")?;
    tl.invalidate().context("Failed to validate TaxonList")?;

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
