use anyhow::{Context, Result};
use std::collections::HashMap;
use std::io::BufRead;
use std::path::PathBuf;

use clap::Parser;
use utils::{now_str, open_read};

fn main() -> Result<()> {
    let args = Cli::parse();

    let reader = open_read(&args.input_file)?;

    let mut current_pept: String = String::new();

    let mut num_prot: u32 = 0;
    let mut num_annotated_go: u32 = 0;
    let mut num_annotated_ec: u32 = 0;
    let mut num_annotated_ip: u32 = 0;
    let mut done: u64 = 0;

    let mut m: HashMap<String, u32> = HashMap::new();

    for line in reader.lines() {
        let line = line.context("Error reading input file")?;
        let row: Vec<&str> = line.split('\t').collect();
        if row[0] != current_pept {
            if !current_pept.is_empty() && !m.is_empty() {
                write_entry(
                    current_pept,
                    num_prot,
                    num_annotated_go,
                    num_annotated_ec,
                    num_annotated_ip,
                    &m,
                );
            }

            m.clear();
            num_prot = 0;
            num_annotated_go = 0;
            num_annotated_ec = 0;
            num_annotated_ip = 0;
            current_pept = row[0].to_string();
        }

        num_prot += 1;

        if row.len() > 1 {
            let terms = row[1].split(';').map(String::from);
            let mut has_ec = false;
            let mut has_go = false;
            let mut has_ip = false;

            for term in terms {
                if term.is_empty() {
                    continue;
                }

                if term.starts_with('G') {
                    has_go = true;
                } else if term.starts_with('E') {
                    has_ec = true;
                } else {
                    has_ip = true;
                }

                *m.entry(term).or_insert(0) += 1;
            }

            if has_go {
                num_annotated_go += 1
            };
            if has_ec {
                num_annotated_ec += 1
            };
            if has_ip {
                num_annotated_ip += 1
            };
        }

        done += 1;

        if done % 1000000 == 0 {
            eprintln!("[{}] FA {} rows", now_str(), done);
        }
    }

    if !m.is_empty() {
        write_entry(
            current_pept,
            num_prot,
            num_annotated_go,
            num_annotated_ec,
            num_annotated_ip,
            &m,
        );
    }

    Ok(())
}

fn write_entry(
    current_peptide: String,
    num_prot: u32,
    num_go: u32,
    num_ec: u32,
    num_ip: u32,
    m: &HashMap<String, u32>,
) {
    let data = m
        .iter()
        .map(|(key, value)| format!(r#""{key}":{value}"#))
        .collect::<Vec<String>>()
        .join(",");

    println!(
        "{current_peptide}\t{{\"num\":{{\"all\":{num_prot},\"EC\":{num_ec},\"GO\":{num_go},\"IPR\":{num_ip}}},\"data\":{{{data}}}}}\n"
    );
}

#[derive(Parser, Debug)]
struct Cli {
    /// TODO
    #[clap(long)]
    input_file: PathBuf,
}
