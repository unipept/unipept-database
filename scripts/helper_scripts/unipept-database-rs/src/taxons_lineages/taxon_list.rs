use std::io::{BufRead, Read};
use std::path::PathBuf;
use std::str::FromStr;

use anyhow::{Context, Error, Result};
use regex::Regex;

use crate::taxons_uniprots_tables::models::{Rank, Taxon};
use crate::utils::files::open_read;

pub struct TaxonList {
    entries: Vec<Option<Taxon>>,
}

impl TaxonList {
    /// Parse a list of Taxons from the names and nodes dumps
    pub fn from_dumps(names_pb: &PathBuf, nodes_pb: &PathBuf) -> Result<Self> {
        let scientific_name = "SCIENTIFIC_NAME";
        let pattern = "\\|";

        let mut entries = vec![];

        let mut names = open_read(names_pb).context("Unable to open names dump file")?;
        let nodes = open_read(nodes_pb).context("Unable to open nodes dump file")?;

        for node_line in nodes.lines() {
            let node_line = node_line.context("Error reading line from nodes dump file")?;
            let node_row: Vec<&str> = node_line.split(pattern).collect();

            let taxon_id = parse_id(node_row[0])?;
            let parent_id = parse_id(node_row[1])?;

            let rank = Rank::from_str(node_row[2].trim()).context("Unable to parse Taxon Rank")?;

            let mut name = String::new();
            let mut clas = String::new();
            let mut taxon_id2 = usize::MAX;

            for name_line in names.by_ref().lines() {
                let name_line = name_line.context("Error reading line from names dump file")?;
                let name_row: Vec<&str> = name_line.split(pattern).collect();
                taxon_id2 = parse_id(name_row[0])?;
                name = name_row[1].trim().to_string();
                clas = name_row[3].trim().to_string();

                if clas == scientific_name {
                    break;
                }
            }

            if clas == scientific_name && taxon_id == taxon_id2 {
                while entries.len() <= taxon_id {
                    entries.push(None);
                }

                entries[taxon_id] = Some(Taxon::new(
                    name,
                    rank,
                    parent_id,
                    true,
                ));
            } else {
                return Err(Error::msg(format!("Taxon {} did not have a scientific name", taxon_id)));
            }
        }

        Ok(TaxonList {
            entries,
        })
    }

    pub fn invalidate(&mut self) -> Result<()> {
        for i in 0..self.entries.len() {
            self.validate(i)?;
        }

        Ok(())
    }

    fn validate(&mut self, id: usize) -> Result<bool> {
        let re = Regex::new(r".*\\d.*").context("Failed to initialize regex")?;

        let taxon = self.entries.get_mut(id).with_context(|| format!("Missing Taxon with id {}", id))?;
        let taxon = match taxon {
            Some(t) => t,
            None => return Ok(false),
        };

        // TODO big if statement
        if !taxon.valid
            || (taxon.rank == Rank::Species
            && (
            (re.is_match(taxon.name.as_str()) && !taxon.name.contains("virus"))
                || taxon.name.ends_with(" sp.")
                || taxon.name.ends_with(" genomosp.")
                || taxon.name.ends_with(" bacterium")
        )
        )
            || taxon.name.contains("enrichment culture")
            || taxon.name.contains("mixed culture")
            || taxon.name.contains("uncultured")
            || taxon.name.contains("unidentified")
            || taxon.name.contains("unspecified")
            || taxon.name.contains("undetermined")
            || taxon.name.contains("sample")
            || taxon.name.ends_with("metagenome")
            || taxon.name.ends_with("library")
            || id == 28384
            || id == 48479
            || id == 1869227 {
            taxon.valid = false;
            return Ok(false);
        }

        if id == 1 {
            return Ok(true);
        }

        let parent = taxon.parent;
        let parent_valid = self.validate(parent)?;

        // I don't like this duplication but we have to do it because of the borrow checker
        // Otherwise, the recursive call above ^ will cause two mutable references at the same time
        // And we need one to mark the taxon as invalid
        let taxon = self.entries.get_mut(id).with_context(|| format!("Missing Taxon with id {}", id))?;
        let taxon = match taxon {
            Some(t) => t,
            None => return Ok(false),
        };

        if !parent_valid {
            taxon.valid = false;
        }

        return Ok(taxon.valid);
    }

    pub fn get(&self, i: usize) -> &Option<Taxon> {
        &self.entries[i]
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

fn parse_id(v: &str) -> Result<usize> {
    v.trim().parse::<usize>().with_context(|| format!("Unable to parse {} as usize", v))
}
