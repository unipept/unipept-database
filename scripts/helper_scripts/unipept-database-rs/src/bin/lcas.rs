use std::path::PathBuf;
use clap::Parser;
use unipept::calculate_lcas::taxonomy::Taxonomy;

#[derive(Parser)]
struct Cli {
    #[clap(long)]
    infile: PathBuf
}

fn main() {
    let args = Cli::parse();
    let _ = Taxonomy::build(&args.infile);
}
