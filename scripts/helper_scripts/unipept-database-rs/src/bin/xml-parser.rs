use std::io::{BufReader, Stdin};
use std::num::NonZeroUsize;

use anyhow::{Context, Result};
use clap::Parser;
use smartstring::{LazyCompact, SmartString};
use uniprot::uniprot::{SequentialParser, ThreadedParser};
use unipept_database::uniprot::UniprotType;

use unipept_database::utils::files::open_sin;

fn main() -> Result<()> {
    let args = Cli::parse();

    let reader = open_sin();

    write_header();

    // Create a different parser based on the amount of threads requested
    match args.threads {
        1 => {
            for r in SequentialParser::new(reader) {
                let entry = r.context("Error reading UniProt entry from SequentialParser")?;
                write_entry(&entry, &args.uniprot_type, args.verbose);
            }
        }
        n => {
            let parser: ThreadedParser<BufReader<Stdin>> = if n == 0 {
                ThreadedParser::new(reader)
            } else {
                ThreadedParser::with_threads(
                    reader,
                    NonZeroUsize::new(n as usize)
                        .context("Error parsing number of threads as usize")?,
                )
            };

            for r in parser {
                let entry = r.context("Error reading UniProt entry from ThreadedParser")?;
                write_entry(&entry, &args.uniprot_type, args.verbose);
            }
        }
    }

    Ok(())
}

type SmartStr = SmartString<LazyCompact>;

// Parse a Uniprot XML file and convert it into a TSV-file
#[derive(Parser, Debug)]
struct Cli {
    #[clap(value_enum, short = 't', long, default_value_t = UniprotType::Swissprot)]
    uniprot_type: UniprotType,
    #[clap(long, default_value_t = 0)]
    threads: u32,
    #[clap(short, long, default_value_t = false)]
    verbose: bool,
}

/// Write the header line to stdout
fn write_header() {
    let fields: [&str; 9] = [
        "Entry",
        "Sequence",
        "Protein names",
        "Version (entry)",
        "EC number",
        "Gene ontology IDs",
        "Cross-reference (InterPro)",
        "Status",
        "Organism ID",
    ];

    let result_string = fields.join("\t");
    println!("{}", result_string);
}

/// Resolve the name of a single entry
fn parse_name(entry: &uniprot::uniprot::Entry) -> SmartStr {
    let mut submitted_name: SmartStr = SmartStr::new();

    // Check the last "recommended" name from a protein's components,
    // otherwise store the last "submitted" name of these components for later
    for component in entry.protein.components.iter().rev() {
        if let Some(n) = &component.recommended {
            return n.full.clone();
        }

        if submitted_name.is_empty() {
            if let Some(n) = component.submitted.last() {
                submitted_name = n.full.clone();
            }
        }
    }

    // Do the same thing for the domains
    for domain in entry.protein.domains.iter().rev() {
        if let Some(n) = &domain.recommended {
            return n.full.clone();
        }

        if submitted_name.is_empty() {
            if let Some(n) = domain.submitted.last() {
                submitted_name = n.full.clone();
            }
        }
    }

    // First check the protein's own recommended name,
    // otherwise return the submitted name from above if there was one,
    // otherwise the last submitted name from the protein itself
    if let Some(n) = &entry.protein.name.recommended {
        n.full.clone()
    } else if !submitted_name.is_empty() {
        submitted_name
    } else if let Some(n) = entry.protein.name.submitted.last() {
        n.full.clone()
    } else {
        eprintln!("Could not find a name for entry {}", entry.accessions[0]);
        SmartStr::new()
    }
}

/// Write a single UniProt entry to stdout
fn write_entry(entry: &uniprot::uniprot::Entry, db_type: &UniprotType, verbose: bool) {
    let accession_number: SmartStr = entry.accessions[0].clone();
    let sequence: SmartStr = entry.sequence.value.clone();

    let name: SmartStr = parse_name(entry);

    let version: SmartStr = SmartStr::from(entry.version.to_string());

    let mut ec_references: Vec<&str> = Vec::new();
    let mut go_references: Vec<&str> = Vec::new();
    let mut ip_references: Vec<&str> = Vec::new();
    let mut taxon_id: SmartStr = SmartStr::new();

    // Find the taxon id in the organism
    for reference in &entry.organism.db_references {
        if reference.ty == "NCBI Taxonomy" {
            taxon_id = reference.id.clone();
        }
    }

    // Find the EC, GO and InterPro references in the entry itself
    for reference in &entry.db_references {
        let vector: Option<&mut Vec<&str>> = match reference.ty.as_str() {
            "EC" => Some(&mut ec_references),
            "GO" => Some(&mut go_references),
            "InterPro" => Some(&mut ip_references),
            _ => None,
        };

        if let Some(v) = vector {
            v.push(&reference.id);
        }
    }

    let fields: [SmartStr; 9] = [
        accession_number,
        sequence,
        name,
        version,
        SmartStr::from(ec_references.join(";")),
        SmartStr::from(go_references.join(";")),
        SmartStr::from(ip_references.join(";")),
        SmartStr::from(db_type.to_str()),
        taxon_id,
    ];

    let line = fields.join("\t");

    if verbose {
        eprintln!("INFO VERBOSE: Writing tabular line: {}", line);
    }

    println!("{}", line);
}
