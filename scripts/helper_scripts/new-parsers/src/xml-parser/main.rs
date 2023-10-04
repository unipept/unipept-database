use std::io::{stdin, StdinLock, stdout, StdoutLock, Write};
use std::num::NonZeroUsize;

use clap::Parser;
use uniprot::uniprot::{SequentialParser, ThreadedParser};

#[derive(clap::ValueEnum, Clone, Debug)]
enum UniprotType {
    Swissprot,
    Trembl,
}

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
        "Organism ID"
    ];

    let result_string = fields.join("\t");
    println!("{}", result_string);
}

// Resolve the name of a single entry
fn parse_name(entry: &uniprot::uniprot::Entry) -> String {
    let mut submitted_name: String = String::new();

    // Check the last "recommended" name from a protein's components,
    // otherwise store the last "submitted" name of these components for later
    for component in entry.protein.components.iter().rev() {
        match &component.recommended {
            Some(n) => { return n.full.clone(); }
            None => {}
        }

        if submitted_name.is_empty() {
            if let Some(n) = component.submitted.last() {
                submitted_name = n.full.clone();
            }
        }
    }

    // Do the same thing for the domains
    for domain in entry.protein.domains.iter().rev() {
        match &domain.recommended {
            Some(n) => { return n.full.clone(); }
            None => {}
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
    match &entry.protein.name.recommended {
        Some(n) => { n.full.clone() }
        None => {
            if !submitted_name.is_empty() {
                submitted_name
            } else if let Some(n) = entry.protein.name.submitted.last() {
                n.full.clone()
            } else {
                eprintln!("Could not find a name for entry {}", entry.accessions[0]);
                String::new()
            }
        }
    }
}

// Write a single entry to stdout
fn write_entry(writer: &mut StdoutLock, entry: &uniprot::uniprot::Entry, verbose: bool) {
    let accession_number: String = entry.accessions[0].clone();
    let sequence: String = entry.sequence.value.clone();

    let name: String = parse_name(entry);

    let version: String = entry.version.to_string();

    let mut ec_references: Vec<String> = Vec::new();
    let mut go_references: Vec<String> = Vec::new();
    let mut ip_references: Vec<String> = Vec::new();
    let mut taxon_id: String = String::new();

    // Find the taxon id in the organism
    for reference in &entry.organism.db_references {
        if reference.ty == "NCBI Taxonomy" {
            taxon_id = reference.id.clone();
        }
    }

    // Find the EC, GO and InterPro references in the entry itself
    for reference in &entry.db_references {
        let vector: Option<&mut Vec<String>> = match reference.ty.as_str() {
            "EC" => Some(&mut ec_references),
            "GO" => Some(&mut go_references),
            "InterPro" => Some(&mut ip_references),
            _ => None
        };

        if let Some(v) = vector {
            v.push(reference.id.clone());
        }
    }

    let fields: [String; 9] = [
        accession_number,
        sequence,
        name,
        version,
        ec_references.join(";"),
        go_references.join(";"),
        ip_references.join(";"),
        "swissprot".to_string(),  // TODO check if this is supposed to be swissprot
        taxon_id,
    ];

    let line = fields.join("\t");

    if verbose {
        eprintln!("INFO VERBOSE: Writing tabular line: {}", line);
    }

    if let Err(e) = writer.write(line.as_bytes()) {
        eprintln!("{:?}", e);
    }
}

fn main() {
    let args = Cli::parse();

    let stdin = stdin();
    let reader = stdin.lock();

    let stdout = stdout();
    let mut writer = stdout.lock();

    write_header();

    // Create a different parser based on the amount of threads requested
    match args.threads {
        1 => {
            for r in SequentialParser::new(reader) {
                let entry = r.unwrap();
                write_entry(&mut writer, &entry, args.verbose);
            }
        }
        n => {
            let parser: ThreadedParser<StdinLock> = if n == 0 {
                ThreadedParser::new(reader)
            } else {
                ThreadedParser::with_threads(
                    reader,
                    NonZeroUsize::new(n as usize).expect("number of threads is not a valid non-zero usize"),
                )
            };

            for r in parser {
                let entry = r.unwrap();
                write_entry(&mut writer, &entry, args.verbose);
            }
        }
    }
}
