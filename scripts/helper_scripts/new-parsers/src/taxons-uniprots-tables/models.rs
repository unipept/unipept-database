pub struct Entry {
    min_length: u32,
    max_length: u32,

    // TODO throw away things we don't use
    // These three are actually ints, but they are never used as ints,
    // so there is no use converting/parsing them as such
    accession_number: String,
    version: String,
    taxon_id: String,

    type_: String,
    name: String,
    sequence: String,
    ec_references: Vec<String>,
    go_references: Vec<String>,
    ip_references: Vec<String>,
}

impl Entry {
    pub fn new(min_length: u32, max_length: u32, type_: String, accession_number: String, sequence: String, name: String, version: String, taxon_id: String) -> Self {
        Entry {
            min_length,
            max_length,

            accession_number,
            version,
            taxon_id,
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
                    result.push(String::from_utf8_lossy(&content[start..i+1]).to_string())
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
