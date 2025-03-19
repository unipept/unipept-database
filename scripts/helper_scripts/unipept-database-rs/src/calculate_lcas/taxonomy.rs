use std::collections::HashMap;
use std::io::BufRead;
use std::path::PathBuf;

use anyhow::{Context, Result};

use crate::taxons_uniprots_tables::models::Rank;
use crate::taxons_uniprots_tables::utils::now_str;
use crate::utils::files::{open_read, open_sin};

const RANKS: usize = 29;
const NULL_STRING: &str = "\\N";
const SEPARATOR: &str = "\t";

pub struct Taxonomy {
    taxonomy: Vec<Vec<i32>>,
}

impl Taxonomy {
    pub fn build(infile: &PathBuf) -> Result<Self> {
        let mut taxonomy_map: HashMap<i32, Vec<i32>> = HashMap::new();
        let reader = open_read(infile).context("Unable to open input file")?;

        let mut max = i32::MIN;

        for line in reader.lines() {
            let line = line.with_context(|| {
                format!("Error reading line from input file {}", infile.display())
            })?;

            let mut elements = line.splitn(RANKS, SEPARATOR).map(parse_int);
            let key = elements
                .next()
                .context("Unable to access key at first index of line")??;

            // Note on the collect::<> here: "?" can't be used inside of map() as it is a closure
            // Collecting into a Result<Vec<_>> will stop instantly when it receives one Error
            // https://doc.rust-lang.org/rust-by-example/error/iter_result.html#fail-the-entire-operation-with-collect
            let lineage = elements.collect::<Result<Vec<i32>>>()?;
            taxonomy_map.insert(key, lineage);

            // Keep track of highest key
            if key > max {
                max = key;
            }
        }

        let mut taxonomy = vec![Vec::new(); (max + 1) as usize];

        for (key, value) in taxonomy_map {
            taxonomy[key as usize] = value;
        }

        Ok(Taxonomy { taxonomy })
    }

    pub fn calculate_lcas(&self) -> Result<()> {
        let reader = open_sin();

        let mut current_sequence = String::new();
        let mut taxa: Vec<i32> = Vec::new();

        for (i, line) in reader.lines().enumerate() {
            if i % 10000000 == 0 && i != 0 {
                eprintln!("{}: {}", now_str(), i);
            }

            let line = line.context("error reading line from stdin")?;

            let (sequence, taxon_id) =
                line.split_once(SEPARATOR).context("error splitting line")?;
            let taxon_id: i32 = taxon_id
                .trim_end()
                .parse()
                .context("error parsing taxon id to int")?;

            if current_sequence.is_empty() || current_sequence != sequence {
                if !current_sequence.is_empty() {
                    self.handle_lca(&current_sequence, self.calculate_lca(&taxa));
                }

                current_sequence = sequence.to_string();
                taxa.clear();
            }

            taxa.push(taxon_id);
        }

        self.handle_lca(&current_sequence, self.calculate_lca(&taxa));
        Ok(())
    }

    fn calculate_lca(&self, taxa: &[i32]) -> i32 {
        let mut lca = 1;
        let genus_rank_idx = Rank::Genus.index();
        let species_rank_idx = Rank::Species.index();

        let lineages: Vec<&Vec<i32>> = taxa
            .iter()
            .map(|x| &self.taxonomy[*x as usize])
            .filter(|x| !x.is_empty())
            .collect();

        // Iterate until RANKS - 1 since the root rank is not present in the lineage array
        // (Each array should implicitly start with 1, but this is handled by the default lca value
        // which is set to 1).
        for rank in 0..(RANKS - 1) {
            let final_rank = rank;
            let mut value = -1;

            let iterator = lineages
                .iter()
                .map(|&x| x[final_rank as usize])
                .filter(|&x| {
                    if final_rank == genus_rank_idx || final_rank == species_rank_idx {
                        x > 0
                    } else {
                        x >= 0
                    }
                });

            // Check if all elements in the iterator are the same
            // This was near-impossible to do with the iterators above,
            // so we're using a simplified loop here
            for item in iterator {
                if value == -1 {
                    value = item;
                } else if item != value {
                    return lca;
                }
            }

            // If we found a new value that matched for all of them, use this as the new best
            if value > 0 {
                lca = value;
            }
        }

        lca
    }

    fn handle_lca(&self, sequence: &String, lca: i32) {
        println!("{}\t{}", sequence, lca);
    }
}

fn parse_int(s: &str) -> Result<i32> {
    if s == NULL_STRING {
        return Ok(0);
    }

    s.parse::<i32>()
        .with_context(|| format!("Error parsing {} as an integer", s))
}
