use std::io::BufRead;

use anyhow::Result;
use crossbeam_channel::{bounded, Receiver};
use lazy_static::lazy_static;
use crate::consumer::Consumer;
use crate::entry::UniProtDATEntry;
use crate::producer::Producer;

/// A multi-threaded DAT parser
/// This parser uses one thread to parse chunks of bytes from the `reader` input stream,
/// and `threads` worker threads to parse those into `UniProtDATEntry`s
pub struct ThreadedDATParser<B: BufRead + Send + 'static> {
    producer: Producer<B>,
    consumers: Vec<Consumer>,
    threads: usize,
    r_parsed: Option<Receiver<Result<UniProtDATEntry>>>,
    started: bool,
}

impl<B: BufRead + Send + 'static> ThreadedDATParser<B> {
    /// Create a new ThreadedParser with `threads` consumer threads.
    /// Passing 0 as the amount of threads uses the amount of (virtual) CPUs available in your machine
    pub fn new(reader: B, mut threads: usize) -> Self {
        if threads == 0 {
            lazy_static! {
                static ref THREADS: usize = num_cpus::get();
            }
            threads = *THREADS
        }

        let producer = Producer::new(reader);
        let mut consumers = Vec::<Consumer>::with_capacity(threads);

        for _ in 0..threads {
            consumers.push(Consumer::new());
        }

        Self {
            producer,
            consumers,
            threads,
            r_parsed: None,
            started: false,
        }
    }

    /// Create communication channels for the producer and consumers,
    /// and launch them in threads
    fn start(&mut self) {
        let (s_raw, r_raw) = bounded::<Vec<u8>>(self.threads * 2);
        let (s_parsed, r_parsed) = bounded::<Result<UniProtDATEntry>>(self.threads * 2);

        self.producer.start(s_raw.clone());

        for consumer in &mut self.consumers {
            consumer.start(r_raw.clone(), s_parsed.clone());
        }

        self.r_parsed = Some(r_parsed);
        self.started = true;
    }

    fn join(&mut self) {
        self.producer.join();
        for consumer in self.consumers.iter_mut() {
            consumer.join();
        }
    }
}

impl<B: BufRead + Send + 'static> Iterator for ThreadedDATParser<B> {
    type Item = Result<UniProtDATEntry>;

    fn next(&mut self) -> Option<Self::Item> {
        if !self.started {
            self.start();
        }

        match &self.r_parsed {
            Some(receiver) => {
                match receiver.recv() {
                    Ok(entry) => Some(entry),
                    // An error is raised when the channel becomes disconnected,
                    // so we don't actually have to handle the error here
                    // it's just a sign that we're done parsing
                    Err(_) => {
                        self.join();
                        None
                    }
                }
            }
            // We never started (unreachable case in practice)
            None => None,
        }
    }
}
