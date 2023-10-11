use std::path::PathBuf;
use clap::Parser;

#[derive(Parser, Debug)]
struct Cli {
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

fn main() {
    let args = Cli::parse();
}
