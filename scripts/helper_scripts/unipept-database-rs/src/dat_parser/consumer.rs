use crate::dat_parser::entry::UniProtDATEntry;
use anyhow::{Context, Result};
use crossbeam_channel::{Receiver, Sender};
use std::thread;
use std::thread::JoinHandle;

/// A Consumer runs in a thread and constantly listens to a Receiver channel for raw data,
/// publishing parsed `UniProtDatEntry`s to a Sender channel
pub struct Consumer {
    handle: Option<JoinHandle<()>>,
}

impl Consumer {
    pub fn new() -> Self {
        Self { handle: None }
    }

    pub fn start(&mut self, receiver: Receiver<Vec<u8>>, sender: Sender<Result<UniProtDATEntry>>) {
        self.handle = Some(thread::spawn(move || {
            for data in receiver {
                // Cut out the \n// at the end
                let data_slice = &data[..data.len() - 3];
                let mut lines: Vec<String> = String::from_utf8_lossy(data_slice)
                    .split("\n")
                    .map(|x| x.to_string())
                    .collect();

                let entry =
                    UniProtDATEntry::from_lines(&mut lines).context("Error parsing DAT entry");
                sender
                    .send(entry)
                    .context("Error sending parsed DAT entry to receiver channel")
                    .unwrap();
            }
        }));
    }

    pub fn join(&mut self) {
        if let Some(h) = self.handle.take() {
            h.join().unwrap();
            self.handle = None;
        }
    }
}
