use strum::{Display, EnumCount, EnumIter, EnumString};

pub const RANKS: usize = 29;

#[rustfmt::skip]
// `NoRank` is the NCBI rank "no rank"; the name is kept for the crates that match on it.
#[allow(clippy::enum_variant_names)]
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
    pub valid: bool
}

impl Taxon {
    pub fn new(name: String, rank: Rank, parent: usize, valid: bool) -> Self {
        Taxon { name, rank, parent, valid }
    }
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use strum::{EnumCount, IntoEnumIterator};

    use super::*;

    /// A lineage row has one column per rank, in this order. unipept-api's `RANK_NAMES` lists the
    /// same ranks after `no rank`, so a change here must be made there too.
    const RANK_NAMES: [&str; RANKS] = [
        "no rank",
        "domain",
        "realm",
        "kingdom",
        "subkingdom",
        "superphylum",
        "phylum",
        "subphylum",
        "superclass",
        "class",
        "subclass",
        "superorder",
        "order",
        "suborder",
        "infraorder",
        "superfamily",
        "family",
        "subfamily",
        "tribe",
        "subtribe",
        "genus",
        "subgenus",
        "species group",
        "species subgroup",
        "species",
        "subspecies",
        "strain",
        "varietas",
        "forma"
    ];

    #[test]
    fn test_ranks_are_named_and_ordered() {
        assert_eq!(Rank::COUNT, RANKS);

        for (index, (rank, name)) in Rank::iter().zip(RANK_NAMES).enumerate() {
            assert_eq!(rank.to_string(), name);
            assert_eq!(Rank::from_str(name).unwrap(), rank);
            assert_eq!(rank.index(), index);
        }
    }

    #[test]
    fn test_unknown_rank_is_an_error() {
        assert!(Rank::from_str("clade").is_err());
    }
}
