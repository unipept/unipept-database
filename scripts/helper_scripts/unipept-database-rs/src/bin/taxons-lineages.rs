use std::path::PathBuf;
use clap::Parser;
use unipept_database::taxons_lineages::taxon_list::TaxonList;
use anyhow::{Context, Result};

fn main() -> Result<()>{
    let args = Cli::parse();

    let mut tl = TaxonList::from_dumps(&args.names, &args.nodes).context("Failed to parse TaxonList from dumps")?;
    eprintln!("Done loading dumps");
    tl.invalidate().context("Failed to validate TaxonList")?;
    eprintln!("Done invalidating");
    tl.write_taxons(&args.taxons).context("Failed to write TaxonList")?;
    eprintln!("Done writing taxons");
    tl.write_lineages(&args.lineages).context("Failed to write lineages")?;

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
