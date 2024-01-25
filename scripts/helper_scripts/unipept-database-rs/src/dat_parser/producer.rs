use std::io::BufRead;
use std::thread;
use std::thread::JoinHandle;
use crossbeam_channel::Sender;

pub struct Producer<B: BufRead + Send + 'static, > {
    reader: Option<B>,
    handle: Option<JoinHandle<()>>,
}

impl <B: BufRead + Send + 'static, > Producer<B> {
    pub fn new(reader: B) -> Self {
        Self {
            reader: Some(reader),
            handle: None
        }
    }

    pub fn start(&mut self, sender: Sender<Vec<u8>>) {
        let mut reader = self.reader.take().unwrap();

        self.handle = Some(thread::spawn(move || {
            let mut buffer: [u8; 64 * 1024] = [0; 64 * 1024];

            // Backup buffer is of variable size because we don't know how big an entry can get
            let mut backup_buffer = Vec::<u8>::new();

            loop {
                let bytes_read = reader.read(&mut buffer).unwrap();

                // Reached EOF
                if bytes_read == 0 {
                    break;
                }

                let mut start_index = 0;

                for i in 0..bytes_read {
                    // We found a slash: check if it is preceded by another slash and a newline
                    if buffer[i] == b'/' {
                        let backup_buffer_size = backup_buffer.len();

                        // A slash is never in the beginning of the file, so we can safely look into the backup buffer
                        // and assume it is not empty: if i == 0, then something must be in the backup buffer
                        let previous_char = if i > 0 { buffer[i - 1] } else { backup_buffer[backup_buffer_size - 1] };
                        let second_previous_char = if i > 1 { buffer[i - 2] } else if i == 1 { backup_buffer[backup_buffer_size - 1] } else { backup_buffer[backup_buffer_size - 2] } ;

                        // Found a separator for a chunk!
                        // Send it to the receivers
                        if previous_char == b'/' && second_previous_char == b'\n' {
                            let mut data = Vec::<u8>::with_capacity(backup_buffer_size + (i + 1 - start_index));

                            // Start out with backup buffer contents if they exist
                            if backup_buffer_size != 0 {
                                data.extend_from_slice(&backup_buffer[..backup_buffer_size]);
                                backup_buffer.clear();
                            }

                            data.extend_from_slice(&buffer[start_index..=i]);
                            sender.send(data).unwrap();

                            // The next chunk will start at offset i+2 because we skip the next newline as well
                            start_index = i + 2;
                        }
                    }
                }

                // Copy the rest over into a buffer for later
                if start_index < bytes_read {
                    backup_buffer.extend_from_slice(&buffer[start_index..bytes_read]);
                }
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

