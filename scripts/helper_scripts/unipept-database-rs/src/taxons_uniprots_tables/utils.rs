use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("Unable to get system time")?
        .as_millis())
}

pub fn now_str() -> Result<String> {
    let n = now().context("Unable to get current time")?;
    let dt: DateTime<Utc> = SystemTime::now().into();
    Ok(format!("{} ({})", n, dt.format("%+")))
}
