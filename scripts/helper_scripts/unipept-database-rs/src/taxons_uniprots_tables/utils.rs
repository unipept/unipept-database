use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Utc};

pub fn now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Error getting system time")
        .as_millis()
}

pub fn now_str() -> String {
    let n = now();
    let dt: DateTime<Utc> = SystemTime::now().into();
    format!("{} ({})", n, dt.format("%+"))
}
