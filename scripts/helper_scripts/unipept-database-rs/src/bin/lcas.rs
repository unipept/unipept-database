use std::path::PathBuf;
use clap::Parser;
use unipept_database::calculate_lcas::taxonomy::Taxonomy;
use unipept_database::taxons_uniprots_tables::utils::now_str;
use anyhow::{Context, Result};

#[derive(Parser)]
struct Cli {
    #[clap(long)]
    infile: PathBuf
}

fn main() -> Result<()> {
    let args = Cli::parse();

    eprintln!("{}: reading taxonomy", now_str()?);
    let tax = Taxonomy::build(&args.infile).context("Unable to build taxonomy")?;

    eprintln!("{}: reading sequences", now_str()?);
    Ok(tax.calculate_lcas()?)
}
