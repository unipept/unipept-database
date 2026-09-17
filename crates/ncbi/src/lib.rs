use strum_macros::{Display, EnumCount, EnumIter, EnumString};

pub const RANKS: usize = 29;

#[rustfmt::skip]
#[derive(PartialEq, Eq, Debug, Clone, Copy, Display, EnumString, EnumCount, EnumIter)]
pub enum Rank {
    #[strum(serialize="no rank")]                     NoRank,
    #[strum(serialize="domain")]                      Domain,
    #[strum(serialize="realm")]                       Realm,
    #[strum(serialize="kingdom")]                     Kingdom,
    #[strum(serialize="subkingdom")]                  Subkingdom,
    #[strum(serialize="superphylum")]                 Superphylum,
    #[strum(serialize="phylum")]                      Phylum,
    #[strum(serialize="subphylum")]                   Subphylum,
    #[strum(serialize="superclass")]                  Superclass,
    #[strum(serialize="class")]                       Class,
    #[strum(serialize="subclass")]                    Subclass,
    #[strum(serialize="superorder")]                  Superorder,
    #[strum(serialize="order")]                       Order,
    #[strum(serialize="suborder")]                    Suborder,
    #[strum(serialize="infraorder")]                  Infraorder,
    #[strum(serialize="superfamily")]                 Superfamily,
    #[strum(serialize="family")]                      Family,
    #[strum(serialize="subfamily")]                   Subfamily,
    #[strum(serialize="tribe")]                       Tribe,
    #[strum(serialize="subtribe")]                    Subtribe,
    #[strum(serialize="genus")]                       Genus,
    #[strum(serialize="subgenus")]                    Subgenus,
    #[strum(serialize="species group")]               SpeciesGroup,
    #[strum(serialize="species subgroup")]            SpeciesSubgroup,
    #[strum(serialize="species")]                     Species,
    #[strum(serialize="subspecies")]                  Subspecies,
    #[strum(serialize="strain")]                      Strain,
    #[strum(serialize="varietas")]                    Varietas,
    #[strum(serialize="forma")]                       Forma,
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
