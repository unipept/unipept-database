use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter};
use std::path::PathBuf;

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