use std::str::FromStr;

use anyhow::{Context, Error, Result};

#[derive(Debug)]
pub struct Entry {
    pub min_length: u32,
    pub max_length: u32,

    // The "version" and "accession_number" fields are actually integers, but they are never used as such,
    // so there is no use converting/parsing them
    pub accession_number: String,
    pub version: String,
    pub taxon_id: i32,

    pub type_: String,
    pub name: String,
    pub sequence: String,
    pub ec_references: Vec<String>,
    pub go_references: Vec<String>,
    pub ip_references: Vec<String>,
}

impl Entry {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        min_length: u32,
        max_length: u32,
        type_: String,
        accession_number: String,
        sequence: String,
        name: String,
        version: String,
        taxon_id: String,
        ec_references: Vec<String>,
        go_references: Vec<String>,
        ip_references: Vec<String>,
    ) -> Result<Self> {
        let parsed_id = taxon_id
            .parse()
            .with_context(|| format!("Failed to parse {} to i32", taxon_id))?;

        Ok(Entry {
            min_length,
            max_length,

            accession_number,
            version,
            taxon_id: parsed_id,
            type_,
            name,
            sequence,

            ec_references,
            go_references,
            ip_references,
        })
    }
}

pub fn calculate_entry_digest(
    sequence: &String,
    min_length: usize,
    max_length: usize,
) -> Vec<&[u8]> {
    let mut result = Vec::new();

    let mut start: usize = 0;
    let length = sequence.len();
    let content = sequence.as_bytes();

    for (i, c) in content.iter().enumerate() {
        if (*c == b'K' || *c == b'R') && (i + 1 < length && content[i + 1] != b'P') {
            if i + 1 - start >= min_length && i + 1 - start <= max_length {
                result.push(&content[start..i + 1]);
            }

            start = i + 1;
        }
    }

    // Add last one
    if length - start >= min_length && length - start <= max_length {
        result.push(&content[start..length]);
    }

    result
}

#[derive(Debug)]
pub enum Rank {
    NoRank,
    SuperKingdom,
    Kingdom,
    SubKingdom,
    SuperPhylum,
    Phylum,
    SubPhylum,
    SuperClass,
    Class,
    SubClass,
    SuperOrder,
    Order,
    SubOrder,
    InfraOrder,
    SuperFamily,
    Family,
    SubFamily,
    Tribe,
    SubTribe,
    Genus,
    SubGenus,
    SpeciesGroup,
    SpeciesSubgroup,
    Species,
    SubSpecies,
    Strain,
    Varietas,
    Forma,
}

impl FromStr for Rank {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_uppercase().replace(' ', "_").as_str() {
            "CLASS" => Ok(Self::Class),
            "FAMILY" => Ok(Self::Family),
            "FORMA" => Ok(Self::Forma),
            "GENUS" => Ok(Self::Genus),
            "INFRAORDER" => Ok(Self::InfraOrder),
            "KINGDOM" => Ok(Self::Kingdom),
            "NO_RANK" => Ok(Self::NoRank),
            "ORDER" => Ok(Self::Order),
            "PHYLUM" => Ok(Self::Phylum),
            "SPECIES" => Ok(Self::Species),
            "SPECIES_GROUP" => Ok(Self::SpeciesGroup),
            "SPECIES_SUBGROUP" => Ok(Self::SpeciesSubgroup),
            "STRAIN" => Ok(Self::Strain),
            "SUBCLASS" => Ok(Self::SubClass),
            "SUBFAMILY" => Ok(Self::SubFamily),
            "SUBGENUS" => Ok(Self::SubGenus),
            "SUBKINGDOM" => Ok(Self::SubKingdom),
            "SUBORDER" => Ok(Self::SubOrder),
            "SUBPHYLUM" => Ok(Self::SubPhylum),
            "SUBSPECIES" => Ok(Self::SubSpecies),
            "SUBTRIBE" => Ok(Self::SubTribe),
            "SUPERCLASS" => Ok(Self::SuperClass),
            "SUPERFAMILY" => Ok(Self::SuperFamily),
            "SUPERKINGDOM" => Ok(Self::SuperKingdom),
            "SUPERORDER" => Ok(Self::SuperOrder),
            "SUPERPHYLUM" => Ok(Self::SuperPhylum),
            "TRIBE" => Ok(Self::Tribe),
            "VARIETAS" => Ok(Self::Varietas),
            _ => Err(Error::msg(format!(
                "Value {} does not match any known ranks",
                s
            ))),
        }
    }
}

#[allow(dead_code)] // The fields in this struct aren't used YET, but will be later on
#[derive(Debug)]
pub struct Taxon {
    name: String,
    rank: Rank,
    parent: usize,
    valid: bool,
}

impl Taxon {
    pub fn new(name: String, rank: Rank, parent: usize, valid: bool) -> Self {
        Taxon {
            name,
            rank,
            parent,
            valid,
        }
    }
}
