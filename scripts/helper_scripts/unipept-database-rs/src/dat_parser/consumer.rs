use std::thread;
use std::thread::JoinHandle;
use crossbeam_channel::{Receiver, Sender};
use crate::dat_parser::entry::UniProtEntry;

pub struct Consumer {
    handle: Option<JoinHandle<()>>,
}

impl Consumer {
    pub fn new() -> Self {
        Self {
            handle: None
        }
    }

    pub fn start(&mut self, receiver: Receiver<Vec<u8>>, sender: Sender<UniProtEntry>) {
        self.handle = Some(thread::spawn(move || {
            for data in receiver {
                // Cut out the \n// at the end
                let data_slice = &data[..data.len()-3];
                let mut lines: Vec<String> = String::from_utf8_lossy(data_slice).split("\n").map(|x| x.to_string()).collect();

                let entry = UniProtEntry::from_lines(&mut lines).unwrap();
                sender.send(entry).unwrap();
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
