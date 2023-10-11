use std::str::FromStr;

pub struct Entry {
    pub min_length: u32,
    pub max_length: u32,

    // These three are actually ints, but sthey are never used as ints,
    // so there is no use converting/parsing them as such
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
    pub fn new(min_length: u32, max_length: u32, type_: String, accession_number: String, sequence: String, name: String, version: String, taxon_id: String) -> Self {
        Entry {
            min_length,
            max_length,

            accession_number,
            version,
            taxon_id: taxon_id.parse().unwrap(),
            type_,
            name,
            sequence,

            ec_references: Vec::new(),
            go_references: Vec::new(),
            ip_references: Vec::new(),
        }
    }

    pub fn digest(&mut self) -> Vec<String> {
        let mut result = Vec::new();

        let mut start: usize = 0;
        let length = self.sequence.len();
        let content = self.sequence.as_bytes();

        for (i, c) in content.iter().enumerate() {
            if (*c == b'K' || *c == b'R') && i + 1 < length && content[i] != b'P' {
                if i + 1 - start >= self.min_length as usize && i + 1 - start <= self.max_length as usize {
                    result.push(String::from_utf8_lossy(&content[start..i + 1]).to_string())
                }

                start = i + 1;
            }
        }

        // Add last one
        if length - start >= self.min_length as usize && length - start <= self.max_length as usize {
            result.push(String::from_utf8_lossy(&content[start..length]).to_string())
        }

        result
    }
}

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
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_uppercase().replace(" ", "_").as_str() {
            "NO_RANK" => Ok(Self::NoRank),
            // TODO others
            _ => Err(())
        }
    }
}

pub struct Taxon {
    name: String,
    rank: Rank,
    parent: u32,
    valid: bool,
}

impl Taxon {
    pub fn new(name: String, rank: Rank, parent: u32, valid: bool) -> Self {
        Taxon {
            name,
            rank,
            parent,
            valid,
        }
    }
}