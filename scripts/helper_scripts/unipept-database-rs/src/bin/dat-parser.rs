use anyhow::Result;
use clap::Parser;
use unipept_database::dat_parser::uniprot_dat_parser;
use unipept_database::dat_parser::utils::write_header;
use unipept_database::uniprot::UniprotType;

use unipept_database::utils::files::open_sin;

fn main() -> Result<()> {
    let args = Cli::parse();
    let reader = open_sin();

    write_header();
    let parser = uniprot_dat_parser(reader, args.threads);

    for entry in parser {
        entry.write(&args.db_type);
    }

    Ok(())
}

#[derive(Parser, Debug)]
struct Cli {
    #[clap(value_enum, short = 't', long, default_value_t = UniprotType::Swissprot)]
    db_type: UniprotType,
    #[clap(long, default_value_t = 0)]
    threads: usize
}
