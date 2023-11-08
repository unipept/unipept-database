use std::path::PathBuf;
use clap::Parser;
use unipept::calculate_lcas::taxonomy::Taxonomy;
use unipept::taxons_uniprots_tables::utils::now_str;

#[derive(Parser)]
struct Cli {
    #[clap(long)]
    infile: PathBuf
}

fn main() {
    let args = Cli::parse();

    eprintln!("{}: reading taxonomy", now_str());
    let tax = Taxonomy::build(&args.infile);

    eprintln!("{}: reading sequences", now_str());
    tax.calculate_lcas();
}
