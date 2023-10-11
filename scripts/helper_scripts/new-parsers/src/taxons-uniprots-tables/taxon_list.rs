use std::io::BufRead;
use std::path::PathBuf;
use std::str::FromStr;
use crate::models::{Rank, Taxon};
use crate::utils::open_read;

pub struct TaxonList {
    entries: Vec<Option<Taxon>>
}

impl TaxonList {
    pub fn from_file(pb: PathBuf) -> Self {
        let mut entries = Vec::new();
        let reader = open_read(&pb);

        for line in reader.lines() {
            let line = line.unwrap();
            let spl: Vec<&str> = line.split("\t").collect();
            let id: u32 = spl[0].parse().expect("unable to parse id");
            let parent: u32 = spl[3].parse().expect("unable to parse parent id");
            if !spl[4].trim().is_empty() {
                eprintln!("Found boolean value: {}", spl[4]);
                std::process::exit(1)
            }
            
            let taxon = Taxon::new(
                spl[1].to_string(),
                Rank::from_str(spl[2]).expect("unable to parse rank"),
                parent,
                false // TODO see if the 5th column is ever not empty
            );

            // TODO check if this makes sense?
            //  If most entries are usually null, use a map instead
            while entries.len() <= id as usize {
                entries.push(None);
            }

            entries[id as usize] = Some(taxon);
        }

        TaxonList {
            entries
        }
    }
}