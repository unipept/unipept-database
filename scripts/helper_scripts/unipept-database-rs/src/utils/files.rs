use std::fs::{File, OpenOptions};
use std::io::{stdin, BufReader, BufWriter, Stdin};
use std::path::PathBuf;
use anyhow::{Context, Result};

/// Create a BufReader that reads from StdIn
pub fn open_sin() -> BufReader<Stdin> {
    BufReader::new(stdin())
}

/// Create a BufReader that reads from a file denoted by its PathBuf
pub fn open_read(pb: &PathBuf) -> Result<BufReader<File>> {
    let file = OpenOptions::new().read(true).open(pb)
        .with_context( || format!("Failed to open file \"{}\" for reading", pb.display()))?;
    Ok(BufReader::new(file))
}

/// Create a BufWriter that writes to a file denoted by its PathBuf
pub fn open_write(pb: &PathBuf) -> Result<BufWriter<File>> {
    let file = OpenOptions::new().write(true).open(pb)
        .with_context( || format!("Failed to open file \"{}\" for writing", pb.display()))?;
    Ok(BufWriter::new(file))
}
