use std::io::{BufRead, Lines};
use crate::dat_parser::entry::UniProtEntry;

pub(crate) struct SequentialParser<B: BufRead> {
    lines: Lines<B>,
    data: Vec<String>,
}

impl<B: BufRead> SequentialParser<B> {
    pub fn new(reader: B) -> Self {
        Self {
            lines: reader.lines(),
            data: Vec::new(),
        }
    }
}

impl<B: BufRead> Iterator for SequentialParser<B> {
    type Item = UniProtEntry;

    fn next(&mut self) -> Option<Self::Item> {
        // A loop combined with Lines.next() is an alternative for a for-loop over Lines,
        // as that takes ownership of the Lines variable (which we don't want/can't do)
        loop {
            let line = self.lines.next();
            if line.is_none() {
                return None;
            }

            let line = line?.unwrap();

            if line == "//" {
                let entry = UniProtEntry::from_lines(&mut self.data);
                self.data.clear();
                return Some(entry.unwrap());
            }

            self.data.push(line);
        }
    }
}
