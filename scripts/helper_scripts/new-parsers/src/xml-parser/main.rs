use std::io::{BufReader, stdin};

use clap::Parser;

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

fn write_entry(entry: &uniprot::uniprot::Entry, verbose: bool) {
    let accession_number: String = entry.accessions[0].clone();
    let sequence: String = entry.sequence.value.clone();

    let name: String = match &entry.protein.name.recommended {
        Some(n) => n.full.clone(),
        None => { entry.protein.name.submitted[0].full.clone() }
    };

    let version: String = entry.version.to_string();

    let mut ec_references: Vec<String> = Vec::new();
    let mut go_references: Vec<String> = Vec::new();
    let mut ip_references: Vec<String> = Vec::new();
    let mut taxon_id: String = String::new();

    for reference in &entry.organism.db_references {
        if reference.ty == "NCBI Taxonomy" {
            taxon_id = reference.id.clone();
        }
    }

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

    println!("{}", line);
}

fn main() {
    let args = Cli::parse();

    let reader = BufReader::new(stdin());

    write_header();

    for r in uniprot::uniprot::parse(reader) {
        let entry = r.unwrap();
        write_entry(&entry, args.verbose);
    }
}
