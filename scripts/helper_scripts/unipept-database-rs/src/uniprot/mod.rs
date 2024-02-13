/// Enum for the different kinds of databases
#[derive(clap::ValueEnum, Clone, Debug)]
pub enum UniprotType {
    Swissprot,
    Trembl,
}

impl UniprotType {
    pub fn to_str(&self) -> &str {
        match self {
            UniprotType::Swissprot => "swissprot",
            UniprotType::Trembl => "trembl",
        }
    }
}
