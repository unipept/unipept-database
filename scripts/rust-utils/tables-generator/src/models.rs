use anyhow::{Context, Result};

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
    pub proteome_references: Vec<String>
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
        proteome_references: Vec<String>
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
            proteome_references
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
