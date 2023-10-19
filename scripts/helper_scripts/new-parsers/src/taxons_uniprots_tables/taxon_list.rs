use std::io::BufRead;
use std::path::PathBuf;

use crate::utils::files::open_read;

// TODO check if content of taxon is ever used - if not, just use something simple instead of a struct
pub struct TaxonList {
    entries: Vec<Option<bool>>,
}

impl TaxonList {
    pub fn from_file(pb: &PathBuf) -> Self {
        let mut entries = Vec::new();
        let reader = open_read(pb);

        for line in reader.lines() {
            let line = line.unwrap();
            let spl: Vec<&str> = line.split('\t').collect();
            let id: u32 = spl[0].parse().expect("unable to parse id");
            let valid = spl[4].trim() == "true";

            while entries.len() <= id as usize {
                entries.push(None);
            }

            entries[id as usize] = Some(valid);
        }

        TaxonList { entries }
    }

    pub fn get(&self, i: usize) -> &Option<bool> {
        &self.entries[i]
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}
