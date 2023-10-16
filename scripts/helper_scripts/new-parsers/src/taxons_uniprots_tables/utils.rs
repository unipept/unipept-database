use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Stdin, stdin};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()
}

pub fn open_sin() -> BufReader<Stdin> {
    BufReader::new(stdin())
}

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