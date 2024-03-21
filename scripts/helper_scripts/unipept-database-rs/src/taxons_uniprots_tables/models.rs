use anyhow::{Context, Result};
use strum_macros::{Display, EnumCount, EnumIter, EnumString};

#[derive(Debug)]
pub struct Entry {
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


// This is taken directly from UMGAP, with Infraclass and Parvorder removed
// Once these changes are merged in UMGAP, this can be replaced with a dependency
// TODO
#[rustfmt::skip]
#[derive(PartialEq, Eq, Debug, Clone, Copy, Display, EnumString, EnumCount, EnumIter)]
pub enum Rank {
    #[strum(serialize="no rank")]          NoRank,
    #[strum(serialize="superkingdom")]     Superkingdom,
    #[strum(serialize="kingdom")]          Kingdom,
    #[strum(serialize="subkingdom")]       Subkingdom,
    #[strum(serialize="superphylum")]      Superphylum,
    #[strum(serialize="phylum")]           Phylum,
    #[strum(serialize="subphylum")]        Subphylum,
    #[strum(serialize="superclass")]       Superclass,
    #[strum(serialize="class")]            Class,
    #[strum(serialize="subclass")]         Subclass,
    #[strum(serialize="superorder")]       Superorder,
    #[strum(serialize="order")]            Order,
    #[strum(serialize="suborder")]         Suborder,
    #[strum(serialize="infraorder")]       Infraorder,
    #[strum(serialize="superfamily")]      Superfamily,
    #[strum(serialize="family")]           Family,
    #[strum(serialize="subfamily")]        Subfamily,
    #[strum(serialize="tribe")]            Tribe,
    #[strum(serialize="subtribe")]         Subtribe,
    #[strum(serialize="genus")]            Genus,
    #[strum(serialize="subgenus")]         Subgenus,
    #[strum(serialize="species group")]    SpeciesGroup,
    #[strum(serialize="species subgroup")] SpeciesSubgroup,
    #[strum(serialize="species")]          Species,
    #[strum(serialize="subspecies")]       Subspecies,
    #[strum(serialize="strain")]           Strain,
    #[strum(serialize="varietas")]         Varietas,
    #[strum(serialize="forma")]            Forma,
}

impl Rank {
    pub fn index(&self) -> usize {
        *self as usize
    }
}

#[derive(Debug)]
pub struct Taxon {
    pub name: String,
    pub rank: Rank,
    pub parent: usize,
    pub valid: bool,
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
