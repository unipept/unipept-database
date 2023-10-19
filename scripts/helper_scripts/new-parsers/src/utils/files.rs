use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Stdin, stdin};
use std::path::PathBuf;

/// Create a BufReader that reads from StdIn
pub fn open_sin() -> BufReader<Stdin> {
    BufReader::new(stdin())
}

/// Create a BufReader that reads from a file denoted by its PathBuf
pub fn open_read(pb: &PathBuf) -> BufReader<File> {
    let file = OpenOptions::new().read(true).open(pb);
    match file {
        Ok(f) => BufReader::new(f),
        Err(e) => {
            eprintln!("{:?}", e);
            std::process::exit(1);
        }
    }
}

/// Create a BufWriter that writes to a file denoted by its PathBuf
pub fn open_write(pb: &PathBuf) -> BufWriter<File> {
    let file = OpenOptions::new().write(true).open(pb);
    match file {
        Ok(f) => BufWriter::new(f),
        Err(e) => {
            eprintln!("{:?}", e);
            std::process::exit(1);
        }
    }
}