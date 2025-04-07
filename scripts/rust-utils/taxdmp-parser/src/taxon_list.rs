use std::io::{BufRead, Read, Write};
use std::path::PathBuf;
use std::str::FromStr;

use anyhow::{Context, Error, Result};
use regex::Regex;
use strum::IntoEnumIterator;
use utils::{open_read, open_write};
use crate::taxon::{Rank, Taxon};

pub struct TaxonList {
    entries: Vec<Option<Taxon>>,
    validation_regex: Regex,
}

impl TaxonList {
    /// Parse a list of Taxons from the names and nodes dumps
    pub fn from_dumps(names_pb: &PathBuf, nodes_pb: &PathBuf) -> Result<Self> {
        let scientific_name = "scientific name";
        let pattern = "|";

        let mut entries = vec![];

        let mut names = open_read(names_pb).context("Unable to open names dump file")?;
        let nodes = open_read(nodes_pb).context("Unable to open nodes dump file")?;

        for node_line in nodes.lines() {
            let node_line = node_line.context("Error reading line from nodes dump file")?;
            let node_row: Vec<&str> = node_line.split(pattern).collect();

            let taxon_id = parse_id(node_row[0])?;
            let parent_id = parse_id(node_row[1])?;

            let rank = Rank::from_str(node_row[2].trim())
                .context("Unable to parse Taxon Rank".to_owned() + node_row[2])?;

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

                entries[taxon_id] = Some(Taxon::new(name, rank, parent_id, true));
            } else {
                return Err(Error::msg(format!(
                    "Taxon {} did not have a scientific name",
                    taxon_id
                )));
            }
        }

        Ok(TaxonList {
            entries,
            validation_regex: Regex::new(r".*\d.*").context("Failed to initialize regex")?,
        })
    }

    pub fn invalidate(&mut self) -> Result<()> {
        for i in 0..self.entries.len() {
            self.validate(i)?;
        }

        Ok(())
    }

    fn validate(&mut self, id: usize) -> Result<bool> {
        let taxon = self
            .entries
            .get_mut(id)
            .with_context(|| format!("Missing Taxon with id {}", id))?;
        let taxon = match taxon {
            Some(t) => t,
            None => return Ok(false),
        };

        if !taxon.valid
            || (taxon.rank == Rank::Species
                && ((self.validation_regex.is_match(taxon.name.as_str())
                    && !taxon.name.contains("virus"))
                    || taxon.name.ends_with(" sp.")
                    || taxon.name.ends_with(" genomosp.")
                    || taxon.name.contains(" bacterium")))
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
            || id == 1869227
        {
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
        let taxon = self
            .entries
            .get_mut(id)
            .with_context(|| format!("Missing taxon with id {}", id))?;
        let taxon = match taxon {
            Some(t) => t,
            None => return Ok(false),
        };

        if !parent_valid {
            taxon.valid = false;
        }

        Ok(taxon.valid)
    }

    pub fn write_taxons(&self, pb: &PathBuf) -> Result<()> {
        let mut writer = open_write(pb).context("Unable to open taxon output file")?;

        for (id, taxon) in self.entries.iter().enumerate() {
            let taxon = if let Some(t) = taxon {
                t
            } else {
                continue;
            };

            let valid = if taxon.valid { '\u{0001}' } else { '\u{0000}' };

            writeln!(
                &mut writer,
                "{}\t{}\t{}\t{}\t{}",
                id, taxon.name, taxon.rank, taxon.parent, valid
            )
            .context("Error writing to taxon TSV file")?;
        }

        Ok(())
    }

    pub fn write_lineages(&self, pb: &PathBuf) -> Result<()> {
        let mut writer = open_write(pb).context("Unable to open lineage output file")?;
        let n_ranks = Rank::iter().count();

        for (i, taxon) in self.entries.iter().enumerate() {
            if taxon.is_none() {
                continue;
            }

            let mut lineage: Vec<String> = vec![String::from("\\N"); n_ranks];
            lineage[0] = i.to_string();

            let mut tid = self.ranked_ancestor(i)?;
            let mut taxon = self.get_taxon_some(tid)?;
            let mut valid = taxon.valid;

            for j in (1..=(n_ranks - 1)).rev() {
                if j > taxon.rank.index() {
                    lineage[j] = if valid {
                        "\\N".to_string()
                    } else {
                        "-1".to_string()
                    };
                } else {
                    valid = taxon.valid;
                    lineage[j] = (if valid { 1 } else { -1 } * (tid as i32)).to_string();
                    tid = self.ranked_ancestor(taxon.parent)?;
                    taxon = self.get_taxon_some(tid)?;
                }
            }

            writeln!(&mut writer, "{}", lineage.join("\t"))
                .context("Error writing to lineage TSV file")?;
        }

        Ok(())
    }

    fn ranked_ancestor(&self, mut tid: usize) -> Result<usize> {
        let mut taxon = self.get_taxon(tid)?;
        let mut pid = usize::MAX;

        // Note: this unwrap() call is safe because of the is_some() beforehand
        while taxon.is_some() && tid != pid && taxon.as_ref().unwrap().rank == Rank::NoRank {
            pid = tid;
            tid = taxon.as_ref().unwrap().parent;
            taxon = self.get_taxon(tid)?;
        }

        if taxon.is_some() {
            return Ok(tid);
        }

        Ok(1) // Used in case a taxon is no descendant of the root
    }

    fn get_taxon(&self, id: usize) -> Result<&Option<Taxon>> {
        self.entries
            .get(id)
            .with_context(|| format!("Invalid taxon id {}", id))
    }

    /// Similar to get_taxon, but unwraps the Option and gives a reference to the Taxon inside of it
    /// This will throw an error if the Taxon is None
    fn get_taxon_some(&self, id: usize) -> Result<&Taxon> {
        if let Some(t) = self.get_taxon(id)? {
            Ok(t)
        } else {
            Err(Error::msg(format!("Missing taxon with id {}", id)))
        }
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
    v.trim()
        .parse::<usize>()
        .with_context(|| format!("Unable to parse {} as usize", v))
}
