use std::io::{BufRead, Lines};

use anyhow::{Context, Result};

use crate::dat_parser::entry::UniProtDATEntry;

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
            let line = match self.lines.next() {
                None => { return None; }
                Some(l) => l.context("Error reading line")
            };

            // Because of the way ? works in an Option<> this can't be done cleanly
            let line = match line {
                Ok(l) => l,
                Err(e) => return Some(Err(e))
            };

            if line == "//" {
                let entry = UniProtDATEntry::from_lines(&mut self.data);
                self.data.clear();
                return Some(entry);
            }

            self.data.push(line);
        }
    }
}
