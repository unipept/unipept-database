use std::io::BufRead;
use std::path::PathBuf;
use std::str::FromStr;
use crate::taxons_uniprots_tables::models::{Rank, Taxon};
use crate::taxons_uniprots_tables::utils::open_read;

// TODO check if content of taxon is ever used - if not, just use something simple instead of a struct
pub struct TaxonList {
    entries: Vec<Option<Taxon>>
}

impl TaxonList {
    pub fn from_file(pb: &PathBuf) -> Self {
        let mut entries = Vec::new();
        let reader = open_read(&pb);

        for line in reader.lines() {
            let line = line.unwrap();
            let spl: Vec<&str> = line.split("\t").collect();
            let id: u32 = spl[0].parse().expect("unable to parse id");
            let parent: u32 = spl[3].parse().expect("unable to parse parent id");
            let valid = spl[4].trim() == "true";
            
            let taxon = Taxon::new(
                spl[1].to_string(),
                Rank::from_str(spl[2]).expect("unable to parse rank"),
                parent,
                valid
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

    pub fn get(&self, i: usize) -> &Option<Taxon> {
        &self.entries[i]
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}