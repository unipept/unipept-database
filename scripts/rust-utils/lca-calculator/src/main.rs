mod taxonomy;

use crate::taxonomy::Taxonomy;
use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use utils::now_str;

fn main() -> Result<()> {
    let args = Cli::parse();

    eprintln!("[{}] Reading taxonomy", now_str());
    let tax = Taxonomy::build(&args.input_file).context("Unable to build taxonomy")?;

    eprintln!("[{}] Reading sequences", now_str());
    tax.calculate_lcas()
}

#[derive(Parser, Debug)]
struct Cli {
    /// TODO
    #[clap(long)]
    input_file: PathBuf,
}
