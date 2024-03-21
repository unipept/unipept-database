use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use unipept_database::taxons_uniprots_tables::tab_parser::TabParser;
use unipept_database::taxons_uniprots_tables::table_writer::TableWriter;

fn main() -> Result<()> {
    let args = Cli::parse();
    let mut writer = TableWriter::new(
        &args.uniprot_entries
    )
    .context("Unable to instantiate TableWriter")?;

    let parser = TabParser::new(args.verbose)
        .context("Unable to instantiate TabParser")?;

    for entry in parser {
        writer
            .store(entry.context("Error getting entry from TabParser")?)
            .context("Error storing entry")?;
    }

    Ok(())
}

#[derive(Parser, Debug)]
pub struct Cli {
    /// Uniprot entries TSV output file
    #[clap(long)]
    uniprot_entries: PathBuf,

    /// Enable verbose mode
    #[clap(short, long, default_value_t = false)]
    verbose: bool,
}
