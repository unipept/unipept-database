use std::fs::{File, OpenOptions};
use std::io::BufReader;
use std::path::PathBuf;

pub fn open(pb: &PathBuf) -> BufReader<File> {
    let file = OpenOptions::new().read(true).open(pb);
    match file {
        Ok(f) => BufReader::new(f),
        Err(e) => {
            eprintln!("{:?}", e);
            std::process::exit(1);
        }
    }
}
