use std::io::{BufRead, Lines};

use crate::entry::UniProtDATEntry;
use anyhow::{Error, Result};

/// A simple single-threaded DAT parser
pub struct SequentialDATParser<B: BufRead> {
    lines: Lines<B>,
    data: Vec<String>,
}

impl<B: BufRead> SequentialDATParser<B> {
    pub fn new(reader: B) -> Self {
        Self {
            lines: reader.lines(),
            data: Vec::new(),
        }
    }
}

impl<B: BufRead> Iterator for SequentialDATParser<B> {
    type Item = Result<UniProtDATEntry>;

    fn next(&mut self) -> Option<Self::Item> {
        // A loop combined with Lines.next() is an alternative for a for-loop over Lines,
        // as that takes ownership of the Lines variable (which we don't want/can't do)
        loop {
            match self.lines.next() {
                None => return None,
                Some(Err(e)) => return Some(Err(Error::new(e).context("Error reading line"))),
                Some(Ok(line)) if line == "//" => {
                    let entry = UniProtDATEntry::from_lines(&self.data);
                    self.data.clear();
                    return Some(entry);
                }
                Some(Ok(line)) => self.data.push(line),
            }
        }
    }
}
