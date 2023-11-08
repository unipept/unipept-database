use clap::Parser;
use std::path::PathBuf;
use anyhow::{Context, Result};
use unipept_database::taxons_uniprots_tables::tab_parser::TabParser;
use unipept_database::taxons_uniprots_tables::table_writer::TableWriter;


fn main() -> Result<()> {
    let args = Cli::parse();
    let mut writer = TableWriter::new(
        &args.taxons,
        &args.peptides,
        &args.uniprot_entries,
        &args.go,
        &args.ec,
        &args.interpro,
    ).context("Unable to instantiate TableWriter")?;

    let parser = TabParser::new(args.peptide_min, args.peptide_max, args.verbose).context("Unable to instantiate TabParser")?;

    for entry in parser {
        writer.store(entry.context("Error getting entry from TabParser")?).context("Error storing entry")?;
    }

    Ok(())
}

#[derive(Parser, Debug)]
pub struct Cli {
    /// Minimum peptide length
    #[clap(long)]
    peptide_min: u32,

    /// Maximum peptide length
    #[clap(long)]
    peptide_max: u32,

    /// Taxons TSV input file
    #[clap(long)]
    taxons: PathBuf,

    /// Peptides TSV output file
    #[clap(long)]
    peptides: PathBuf,

    /// Uniprot entries TSV output file
    #[clap(long)]
    uniprot_entries: PathBuf,

    /// EC references TSV output file
    #[clap(long)]
    ec: PathBuf,

    /// GO references TSV output file
    #[clap(long)]
    go: PathBuf,

    /// InterPro references TSV output file
    #[clap(long)]
    interpro: PathBuf,

    /// Enable verbose mode
    #[clap(short, long, default_value_t = false)]
    verbose: bool,
}
