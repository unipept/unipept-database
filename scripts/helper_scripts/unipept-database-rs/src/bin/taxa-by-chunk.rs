use std::fs::{File, read_dir};
use std::io::{BufRead, BufWriter, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::Parser;
use regex::Regex;

use unipept_database::utils::files::open_sin;

fn main() -> Result<()> {
    let args = Cli::parse();

    let mut all_taxa: Vec<u64> = Vec::new();

    let reader = open_sin();

    // Read all taxa ids from stdin
    for line in reader.lines() {
        let line = line.context("Error reading line from stdin")?;

        // Ignore empty lines
        if line.trim().is_empty() {
            continue;
        }

        let taxa_id: u64 = line.trim().parse().with_context(|| format!("Error parsing {line} as an integer"))?;
        all_taxa.push(taxa_id);
    }

    let chunk_file_regex = Regex::new(r"unipept\..*\.gz").context("Error creating regex")?;

    for entry in read_dir(&args.chunk_dir).context("Error reading chunk directory")? {
        let entry = entry.context("Error reading entry from chunk directory")?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let base_name = match path.file_name() {
            None => {continue;}
            Some(n) => n.to_str().context("Error creating string from file path")?
        };

        if !chunk_file_regex.is_match(base_name) {
            continue;
        }

        // Parse the taxa range out of the filename
        let replaced_name = base_name.replace("unipept.", "").replace(".chunk.gz", "");
        let range = replaced_name.split_once("-");
        let range = range.with_context(|| format!("Unable to split {replaced_name} on '-'"))?;
        let start: u64 = range.0.parse().with_context(|| format!("Error parsing {} as an integer", range.0))?;
        let end: u64 = range.1.parse().with_context(|| format!("Error parsing {} as an integer", range.1))?;

        let matching_taxa: Vec<&u64> = all_taxa.iter().filter(|&t| start <= *t && *t <= end).collect();

        // Write matches to a temporary output file
        if !matching_taxa.is_empty() {
            let mapped_taxa: Vec<String> = matching_taxa.iter().map(|&t| format!("\t{t}$")).collect();
            let joined_taxa = mapped_taxa.join("\n");

            let temp_file_path = Path::new(&args.temp_dir).join(format!("{base_name}.pattern"));
            let temp_file = File::create(&temp_file_path).context("Error creating temporary pattern file")?;
            let mut writer = BufWriter::new(temp_file);
            write!(
                &mut writer,
                "{joined_taxa}",
            ).context("Error writing to temporary pattern file")?;

            // The two unwraps here can't be handled using the ? operator
            println!("{}", temp_file_path.into_os_string().into_string().unwrap());
            println!("{}", path.into_os_string().into_string().unwrap());
        }
    }

    Ok(())
}

#[derive(Parser, Debug)]
struct Cli {
    #[clap(long)]
    chunk_dir: PathBuf,

    #[clap(long)]
    temp_dir: PathBuf
}