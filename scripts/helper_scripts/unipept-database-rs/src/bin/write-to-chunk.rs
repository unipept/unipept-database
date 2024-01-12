use std::fs::File;
use std::io::{BufRead, BufWriter, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::Parser;

use unipept_database::utils::files::open_sin;

fn main() -> Result<()> {
    let args = Cli::parse();

    let mut file_streams: Vec<BufWriter<File>> = Vec::with_capacity(TAXA_BOUNDS.len());

    // Create writers for the output files
    for (idx, bound) in TAXA_BOUNDS.iter().take(TAXA_BOUNDS.len() - 1).enumerate() {
        let next = TAXA_BOUNDS[idx + 1];
        let file_name = format!("unipept.{bound}-{next}.chunk");
        let file_path = Path::new(&args.output_dir).join(file_name);
        let file_handler = File::create(file_path).with_context(|| format!("Unable to create output file {bound}-{next}"))?;
        let writer = BufWriter::new(file_handler);
        file_streams.push(writer);
    }

    let mut reader = open_sin();

    // First read the header
    let mut header: String = String::new();
    reader.read_line(&mut header).context("Error reading header from stdin")?;
    write_header(&args.output_dir, header)?;

    // Then the rest of the data
    for line in reader.lines() {
        let line = line.context("Error reading line from stdin")?;

        if args.verbose {
            eprintln!("INFO VERBOSE: writing line to chunk: {line}");
        }

        let spl: Vec<&str> = line.split('\t').collect();
        let taxon_id = spl[8].trim().parse::<usize>().with_context(|| format!("Error parsing {} as an integer", spl[8]))?;

        // Find the index of this taxon id in the array
        // Note that this can be sped up using binary search (see Python's bisect.bisect_left),
        // but this tool is near-instant so we favour readability
        let mut index: usize = 0;
        while taxon_id > TAXA_BOUNDS[index] {
            index += 1;
        }

        writeln!(&mut file_streams[index], "{line}").context("Error writing to output file")?;
    }

    Ok(())
}

#[derive(Parser, Debug)]
struct Cli {
    #[clap(short, long)]
    output_dir: PathBuf,
    #[clap(short, long)]
    verbose: bool,
}

const TAXA_BOUNDS: [usize; 45] = [
    0, 550, 1352, 3047, 5580, 8663, 11676, 32473, 40214, 52774, 66656, 86630, 116960, 162147, 210225, 267979, 334819,
    408172, 470868, 570509, 673318, 881260, 1046115, 1136135, 1227077, 1300307, 1410620, 1519492, 1650438, 1756149,
    1820614, 1871070, 1898104, 1922217, 1978231, 2024617, 2026757, 2035430, 2070414, 2202732, 2382165, 2527964, 2601669,
    2706029, 10000000
];

fn write_header(output_dir: &PathBuf, header: String) -> Result<()> {
    let file_path = Path::new(output_dir).join("db.header");
    let file_handler = File::create(file_path).with_context(|| format!("Unable to create header output file"))?;
    let mut writer = BufWriter::new(file_handler);

    writeln!(&mut writer, "{}", header).context("Error writing header")?;

    Ok(())
}
