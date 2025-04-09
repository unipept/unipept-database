use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Stdin, stdin};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

/// Create a BufReader that reads from StdIn
pub fn open_sin() -> BufReader<Stdin> {
    BufReader::new(stdin())
}

/// Create a BufReader that reads from a file denoted by its PathBuf
pub fn open_read(pb: &PathBuf) -> Result<BufReader<File>> {
    let file = OpenOptions::new()
        .read(true)
        .open(pb)
        .with_context(|| format!("Failed to open file \"{}\" for reading", pb.display()))?;
    Ok(BufReader::new(file))
}

/// Create a BufWriter that writes to a file denoted by its PathBuf
pub fn open_write(pb: &PathBuf) -> Result<BufWriter<File>> {
    let file = OpenOptions::new()
        .write(true)
        .open(pb)
        .with_context(|| format!("Failed to open file \"{}\" for writing", pb.display()))?;
    Ok(BufWriter::new(file))
}

pub fn now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Error getting system time")
        .as_millis()
}

pub fn now_str() -> String {
    let n = now() / 1000;
    let dt: DateTime<Utc> = SystemTime::now().into();
    format!("{} ({})", n, dt.format("%Y-%m-%d %H:%M:%S"))
}
