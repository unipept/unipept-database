use std::io::BufRead;

mod consumer;
mod producer;
pub mod entry;
pub mod utils;
pub mod sequential_parser;
pub mod threaded_parser;

use self::sequential_parser::SequentialParser;
use self::entry::UniProtEntry;
use self::threaded_parser::ThreadedParser;

pub fn uniprot_dat_parser<B: BufRead + Send + 'static,>(reader: B, threads: usize) -> Box<dyn Iterator<Item=UniProtEntry>> {
    if threads == 1 {
        Box::new(SequentialParser::new(reader))
    } else {
        Box::new(ThreadedParser::new(reader, threads))
    }
}
