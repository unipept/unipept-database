use std::cmp::min;
use std::collections::HashSet;
use std::io::BufRead;
use std::thread;
use std::thread::JoinHandle;

use anyhow::{Context, Result};
use clap::Parser;
use crossbeam_channel::{bounded, Receiver, Sender};

use unipept_database::utils::files::open_sin;

fn main() -> Result<()> {
    let args = Cli::parse();
    let reader = open_sin();
    let (s_raw, r_raw) = bounded::<Vec<u8>>(args.threads * 2);
    let (s_parsed, r_parsed) = bounded::<UniProtEntry>(args.threads * 2);

    write_header();

    let mut parser = ThreadedParser::new(reader);
    let mut consumers = Vec::<Consumer>::with_capacity(args.threads);

    for _ in 0..args.threads {
        consumers.push(Consumer::new());
    }

    parser.start(s_raw.clone());
    for consumer in &mut consumers {
        consumer.start(r_raw.clone(), s_parsed.clone());
    }

    // Drop the original reference to the senders explicitly
    // all other copies are dropped when their threads exit
    // Without this, the program hangs forever because the channels are never closed
    // https://users.rust-lang.org/t/solved-close-channel-in-crossbeam-threads/27396/2
    drop(s_raw);
    drop(s_parsed);

    for entry in r_parsed {
        entry.write(&args.db_type);
    }

    parser.join();
    for consumer in &mut consumers {
        consumer.join();
    }

    Ok(())
}

#[derive(Parser, Debug)]
struct Cli {
    #[clap(value_enum, short = 't', long, default_value_t = UniprotType::Swissprot)]
    db_type: UniprotType,
    #[clap(long, default_value_t = 2)]
    threads: usize,
}

#[derive(clap::ValueEnum, Clone, Debug)]
enum UniprotType {
    Swissprot,
    Trembl,
}

impl UniprotType {
    pub fn to_str(&self) -> &str {
        match self {
            UniprotType::Swissprot => "swissprot",
            UniprotType::Trembl => "trembl",
        }
    }
}

struct ThreadedParser<B: BufRead + Send + 'static, > {
    reader: Option<B>,
    handle: Option<JoinHandle<()>>,
}

impl<B: BufRead + Send + 'static, > ThreadedParser<B> {
    pub fn new(reader: B) -> Self {
        Self {
            reader: Some(reader),
            handle: None,
        }
    }

    pub fn start(&mut self, sender: Sender<Vec<u8>>) {
        let mut reader = self.reader.take().unwrap();

        self.handle = Some(thread::spawn(move || {
            let mut buffer: [u8; 64 * 1024] = [0; 64 * 1024];

            // Backup buffer is of variable size because we don't know how big an entry can get
            let mut backup_buffer = Vec::<u8>::new();

            loop {
                let bytes_read = reader.read(&mut buffer).unwrap();

                // Reached EOF
                if bytes_read == 0 {
                    break;
                }

                let mut start_index = 0;

                for i in 0..bytes_read {
                    // We found a slash: check if it is preceded by another slash and a newline
                    if buffer[i] == b'/' {
                        let backup_buffer_size = backup_buffer.len();

                        // A slash is never in the beginning of the file, so we can safely look into the backup buffer
                        // and assume it is not empty: if i == 0, then something must be in the backup buffer
                        let previous_char = if i > 0 { buffer[i - 1] } else { backup_buffer[backup_buffer_size - 1] };
                        let second_previous_char = if i > 1 { buffer[i - 2] } else if i == 1 { backup_buffer[backup_buffer_size - 1] } else { backup_buffer[backup_buffer_size - 2] } ;

                        // Found a separator for a chunk!
                        // Send it to the receivers
                        if previous_char == b'/' && second_previous_char == b'\n' {
                            let mut data = Vec::<u8>::with_capacity(backup_buffer_size + (i + 1 - start_index));

                            // Start out with backup buffer contents if they exist
                            if backup_buffer_size != 0 {
                                data.extend_from_slice(&backup_buffer[..backup_buffer_size]);
                                backup_buffer.clear();
                            }

                            data.extend_from_slice(&buffer[start_index..=i]);

                            // In edge cases we can copy a bit too much over, cut those parts out
                            // (because of the min() call a few lines down)
                            // Skip bytes until we reach ID
                            // In practice this won't be more than 2-ish bytes
                            let mut to_remove: usize = 0;
                            while !(data[to_remove] == b'I' && data[to_remove + 1] == b'D') {
                                to_remove += 1;
                            }

                            if to_remove != 0 {
                                data.drain(..to_remove);
                            }

                            sender.send(data).unwrap();

                            // The next chunk will start at offset i+2 because we skip the next newline as well
                            start_index = min(i + 2, bytes_read - 1);
                        }
                    }
                }

                // Copy the rest over into a buffer for later
                backup_buffer.extend_from_slice(&buffer[start_index..bytes_read]);
            }
        }));
    }

    pub fn join(&mut self) {
        if let Some(h) = self.handle.take() {
            h.join().unwrap();
            self.handle = None;
        }
    }
}

struct Consumer {
    handle: Option<JoinHandle<()>>,
}

impl Consumer {
    pub fn new() -> Self {
        Self {
            handle: None
        }
    }

    pub fn start(&mut self, receiver: Receiver<Vec<u8>>, sender: Sender<UniProtEntry>) {
        self.handle = Some(thread::spawn(move || {
            for data in receiver {
                // Cut out the \n// at the end
                let data_slice = &data[..data.len()-3];
                let mut lines: Vec<String> = String::from_utf8_lossy(data_slice).split("\n").map(|x| x.to_string()).collect();

                let entry = UniProtEntry::from_lines(&mut lines).unwrap();
                sender.send(entry).unwrap();
            }
        }));
    }

    pub fn join(&mut self) {
        if let Some(h) = self.handle.take() {
            h.join().unwrap();
            self.handle = None;
        }
    }
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
        "Organism ID",
    ];

    let result_string = fields.join("\t");
    println!("{}", result_string);
}

// Constants to aid in parsing
const COMMON_PREFIX_LEN: usize = "ID   ".len();

const ORGANISM_RECOMMENDED_NAME_PREFIX_LEN: usize = "RecName: Full=".len();
const ORGANISM_RECOMMENDED_NAME_EC_PREFIX_LEN: usize = "EC=".len();
const ORGANISM_TAXON_ID_PREFIX_LEN: usize = "OX   NCBI_TaxID=".len();
const VERSION_STRING_FULL_PREFIX_LEN: usize = "DT   08-NOV-2023, entry version ".len();

// Data types
struct UniProtEntry {
    accession_number: String,
    name: String,
    sequence: String,
    version: String,
    ec_references: Vec<String>,
    go_references: Vec<String>,
    ip_references: Vec<String>,
    taxon_id: String,
}

impl UniProtEntry {
    pub fn from_lines(data: &mut Vec<String>) -> Result<Self> {
        let mut current_index: usize;
        let accession_number: String;
        let mut version = String::new();
        let mut name = String::new();
        let mut ec_references = Vec::<String>::new();
        let mut go_references = Vec::<String>::new();
        let mut ip_references = Vec::<String>::new();
        let mut taxon_id = String::new();
        let mut sequence = String::new();

        accession_number = parse_ac_number(data).context("Error parsing accession number")?;
        current_index = parse_version(data, &mut version);
        current_index = parse_name(data, current_index, &mut ec_references, &mut name);
        current_index = parse_taxon_id(data, current_index, &mut taxon_id);
        current_index = parse_db_references(data, current_index, &mut go_references, &mut ip_references);
        parse_sequence(data, current_index, &mut sequence);

        return Ok(Self {
            accession_number,
            name,
            sequence,
            version,
            ec_references,
            go_references,
            ip_references,
            taxon_id,
        });
    }

    pub fn write(&self, db_type: &UniprotType) {
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            self.accession_number,
            self.sequence,
            self.name,
            self.version,
            self.ec_references.join(";"),
            self.go_references.join(";"),
            self.ip_references.join(";"),
            db_type.to_str(),
            self.taxon_id
        )
    }
}

// Functions to parse an Entry out of a Vec<String>
fn parse_ac_number(data: &mut Vec<String>) -> Result<String> {
    // The AC number is always the second element
    let line = &mut data[1];
    line.drain(..COMMON_PREFIX_LEN);
    let (pre, _) = line.split_once(";").with_context(|| format!("Unable to split \"{line}\" on ';'"))?;
    Ok(pre.to_string())
}

fn parse_version(data: &Vec<String>, target: &mut String) -> usize {
    let mut last_field: usize = 2;

    // Skip past previous fields to get to the dates
    while !data[last_field].starts_with("DT") {
        last_field += 1;
    }

    // The date fields are always the third-n elements
    // The version is always the last one
    while data[last_field + 1].starts_with("DT") {
        last_field += 1;
    }

    // Get entry version (has prefix of constant length and ends with a dot)
    let version_end = data[last_field].len() - 1;
    target.push_str(&(data[last_field][VERSION_STRING_FULL_PREFIX_LEN..version_end]));
    last_field + 1
}

fn parse_name(data: &mut Vec<String>, mut idx: usize, ec_references: &mut Vec<String>, target: &mut String) -> usize {
    // Find where the info starts and ends
    while !data[idx].starts_with("DE") {
        idx += 1;
    }

    let mut ec_reference_set = HashSet::new();
    let mut end_index = idx;

    // Track all names in order of preference:
    // - Last recommended name of protein components
    // - Last recommended name of protein domains
    // - Recommended name of protein itself
    // - Last submitted name of protein components
    // - Last submitted name of protein domains
    // - Submitted name of protein itself
    let mut name_indices: [usize; 6] = [usize::MAX; 6];
    const LAST_COMPONENT_RECOMMENDED_IDX: usize = 0;
    const LAST_COMPONENT_SUBMITTED_IDX: usize = 3;
    const LAST_DOMAIN_RECOMMENDED_IDX: usize = 1;
    const LAST_DOMAIN_SUBMITTED_IDX: usize = 4;
    const LAST_PROTEIN_RECOMMENDED_IDX: usize = 2;
    const LAST_PROTEIN_SUBMITTED_IDX: usize = 5;

    // Keep track of which block we are currently in
    // Order is always protein -> components -> domain
    let mut inside_domain = false;
    let mut inside_component = false;

    while data[end_index].starts_with("DE") {
        let line = &mut data[end_index];
        line.drain(..COMMON_PREFIX_LEN);

        // Marks the start of a Component
        if line == "Contains:" {
            inside_component = true;
            end_index += 1;
            continue;
        }

        // Marks the start of a Domain
        if line == "Includes:" {
            inside_domain = true;
            end_index += 1;
            continue;
        }

        // Remove all other spaces (consecutive lines have leading spaces we don't care for)
        drain_leading_spaces(line);

        // Keep track of the last recommended name
        if line.starts_with("RecName: Full=") {
            if inside_domain {
                name_indices[LAST_DOMAIN_RECOMMENDED_IDX] = end_index;
            } else if inside_component {
                name_indices[LAST_COMPONENT_RECOMMENDED_IDX] = end_index;
            } else {
                name_indices[LAST_PROTEIN_RECOMMENDED_IDX] = end_index;
            }
        }
        // Find EC numbers
        else if line.starts_with("EC=") {
            let mut ec_target = String::new();
            read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_EC_PREFIX_LEN, &mut ec_target);

            if !ec_reference_set.contains(&ec_target) {
                ec_reference_set.insert(ec_target.clone());
                ec_references.push(ec_target);
            }
        }
        // Keep track of the last submitted name
        else if line.starts_with("SubName: Full=") {
            if inside_domain {
                name_indices[LAST_DOMAIN_SUBMITTED_IDX] = end_index;
            } else if inside_component {
                name_indices[LAST_COMPONENT_SUBMITTED_IDX] = end_index;
            } else {
                name_indices[LAST_PROTEIN_SUBMITTED_IDX] = end_index;
            }
        }

        end_index += 1;
    }

    // Choose a name from the ones we encountered
    // Use the first name that we managed to find, in order
    for idx in name_indices {
        if idx != usize::MAX {
            let line = &mut data[idx];
            read_until_metadata(line, ORGANISM_RECOMMENDED_NAME_PREFIX_LEN, target);
            return end_index;
        }
    }

    end_index
}

fn parse_taxon_id(data: &mut Vec<String>, mut idx: usize, target: &mut String) -> usize {
    while !data[idx].starts_with("OX   NCBI_TaxID=") {
        idx += 1;
    }

    let line = &mut data[idx];
    read_until_metadata(line, ORGANISM_TAXON_ID_PREFIX_LEN, target);

    while data[idx].starts_with("OX") {
        idx += 1;
    }

    idx
}

fn parse_db_references(data: &mut Vec<String>, mut idx: usize, go_references: &mut Vec<String>, ip_references: &mut Vec<String>) -> usize {
    let original_idx = idx;
    let length = data.len();

    // Find where references start
    while !data[idx].starts_with("DR") {
        idx += 1;

        // No references present in this entry
        if idx == length {
            return original_idx;
        }
    }

    // Parse all references
    while data[idx].starts_with("DR") {
        let line = &mut data[idx];
        line.drain(..COMMON_PREFIX_LEN);

        parse_db_reference(line, go_references, ip_references);

        idx += 1;
    }

    idx
}

fn parse_db_reference(line: &mut String, go_references: &mut Vec<String>, ip_references: &mut Vec<String>) {
    if line.starts_with("GO;") {
        let substr = &line[4..14];
        go_references.push(substr.to_string());
    } else if line.starts_with("InterPro;") {
        let substr = &line[10..19];
        ip_references.push(substr.to_string());
    } else if line.starts_with("EC") {
        // TODO remove this after testing on trembl
        panic!("Found an EC reference in the DB references");
    }
}

fn parse_sequence(data: &mut Vec<String>, mut idx: usize, target: &mut String) {
    // Find the beginning of the sequence
    // optionally skip over some fields we don't care for
    while !data[idx].starts_with("SQ") {
        idx += 1;
    }

    // First line of the sequence contains some metadata we don't care for
    idx += 1;

    // Combine all remaining lines
    for line in data.iter_mut().skip(idx) {
        line.drain(..COMMON_PREFIX_LEN);
        target.push_str(&line.replace(" ", ""));
    }
}

fn read_until_metadata(line: &mut String, prefix_len: usize, target: &mut String) {
    line.drain(..prefix_len);

    // The line either contains some metadata, or just ends with a semicolon
    // In the latter case, move the position to the end of the string,
    // so we can pretend it is at a bracket and cut the semicolon out
    // If it contains metadata, this wrapped in curly braces after a space
    // (sometimes there are curly braces inside of the name itself, so just a curly is not enough)
    let mut bracket_index = 0;
    let mut previous_char = '\0';

    for (i, c) in line.chars().enumerate() {
        if c == '{' && previous_char == ' ' {
            bracket_index = i;
            break;
        }

        previous_char = c;
    }

    if bracket_index == 0 {
        bracket_index = line.len();
    }

    target.push_str(&(line[..bracket_index - 1]));
}

fn drain_leading_spaces(line: &mut String) {
    for (idx, c) in line.chars().enumerate() {
        if c != ' ' {
            line.drain(..idx);
            break;
        }
    }
}