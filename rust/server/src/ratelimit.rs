//! Rate limits (port of ratelimit.lua): a fixed window per key, shared by
//! every process through the api_rate_limits table, with an in-memory
//! sliding window if the database is unreachable.

use crate::db::{Db, J};
use crate::http::{R, Reply};
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Default)]
pub struct Limiter {
    mem: Mutex<HashMap<String, Vec<i64>>>,
}

const MEM_MAX: usize = 2000;

fn bucket_key(key: &str) -> String {
    let k: String = key.chars().map(|c| if c.is_ascii_alphanumeric() || "_.:@-".contains(c) { c } else { '_' }).collect();
    crate::util::cut(&k, 190)
}

impl Limiter {
    fn mem_allow(&self, key: &str, limit: i64, window: i64) -> bool {
        let now = crate::util::now();
        let mut m = self.mem.lock().unwrap();
        let hits = m.entry(key.to_string()).or_default();
        hits.retain(|t| now - t < window);
        if hits.len() as i64 >= limit {
            return false;
        }
        hits.push(now);
        if m.len() > MEM_MAX {
            if let Some(oldest) = m.iter().min_by_key(|(_, v)| v.last().copied().unwrap_or(0)).map(|(k, _)| k.clone()) {
                m.remove(&oldest);
            }
        }
        true
    }

    pub async fn allow(&self, db: &Db, key: &str, limit: i64, window: i64) -> bool {
        let key = bucket_key(key);
        let (limit, window) = (limit.max(1), window.max(1));
        let sql = format!(
            "INSERT INTO api_rate_limits (bucket_key, window_start, event_count, updated_at) VALUES ($1, now(), 1, now()) \
             ON CONFLICT (bucket_key) DO UPDATE SET \
               event_count = CASE WHEN EXTRACT(EPOCH FROM (now() - api_rate_limits.window_start)) >= {window} THEN 1 ELSE api_rate_limits.event_count + 1 END, \
               window_start = CASE WHEN EXTRACT(EPOCH FROM (now() - api_rate_limits.window_start)) >= {window} THEN now() ELSE api_rate_limits.window_start END, \
               updated_at = now() \
             RETURNING event_count"
        );
        match db.one(&sql, &[key.as_str().into()]).await {
            Ok(Some(row)) => row.i("event_count").unwrap_or(limit + 1) <= limit,
            _ => self.mem_allow(&key, limit, window),
        }
    }

    /// 429 "Too many attempts. Try again later." when over the limit.
    pub async fn check(&self, db: &Db, key: &str, limit: i64, window: i64) -> R<()> {
        if self.allow(db, key, limit, window).await { Ok(()) } else { Err(Reply::err(429, "Too many attempts. Try again later.")) }
    }
}
