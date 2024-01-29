use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use unipept_database::calculate_lcas::taxonomy::Taxonomy;
use unipept_database::taxons_uniprots_tables::utils::now_str;

#[derive(Parser)]
struct Cli {
    #[clap(long)]
    infile: PathBuf,
}

fn main() -> Result<()> {
    let args = Cli::parse();

    eprintln!("{}: reading taxonomy", now_str());
    let tax = Taxonomy::build(&args.infile).context("Unable to build taxonomy")?;

    eprintln!("{}: reading sequences", now_str());
    tax.calculate_lcas()
}
