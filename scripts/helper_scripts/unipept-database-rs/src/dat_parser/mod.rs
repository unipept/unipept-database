use anyhow::Result;
use std::io::BufRead;

mod consumer;
pub mod entry;
mod producer;
pub mod sequential_parser;
pub mod threaded_parser;
pub mod utils;

use self::entry::UniProtDATEntry;
use self::sequential_parser::SequentialDATParser;
use self::threaded_parser::ThreadedDATParser;

/// Create a SequentialParser or ThreadedParser based on the amount of threads passed
pub fn uniprot_dat_parser<B: BufRead + Send + 'static>(
    reader: B,
    threads: usize,
) -> Box<dyn Iterator<Item = Result<UniProtDATEntry>>> {
    if threads == 1 {
        Box::new(SequentialDATParser::new(reader))
    } else {
        Box::new(ThreadedDATParser::new(reader, threads))
    }
}
