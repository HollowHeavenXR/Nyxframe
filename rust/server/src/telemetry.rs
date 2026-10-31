//! Backend telemetry (port of telemetry.lua).
//!
//! Per-request stats, job snapshots and action counters stay in memory
//! (bucketed by route pattern, reset hourly). Only real operations write a
//! `telemetry_events` row: uploads, auth attempts, job runs that did
//! something or failed, and client media diagnostics. Writes are queued and
//! flushed in batches so they never sit on a request's path.

use crate::db::{Db, P};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

const REQUEST_STATS_RESET_SECONDS: i64 = 3600;
const SAMPLE_CAP: usize = 50;

#[derive(Default)]
struct Bucket {
    count: i64,
    error_count: i64,
    total_ms: f64,
    max_ms: f64,
    samples: std::collections::VecDeque<f64>,
}

struct Row {
    event_type: String,
    subject: Option<String>,
    outcome: Option<String>,
    duration_ms: Option<i64>,
    meta: Option<Value>,
}

#[derive(Default)]
struct Mem {
    requests: HashMap<String, Bucket>,
    since: i64,
    jobs: serde_json::Map<String, Value>,
    counters: serde_json::Map<String, Value>,
}

pub struct Telemetry {
    enabled: bool,
    tx: mpsc::UnboundedSender<Row>,
    mem: Mutex<Mem>,
    db: Arc<Db>,
}

impl Telemetry {
    pub fn start(db: Arc<Db>, enabled: bool) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel::<Row>();
        let flush_db = db.clone();
        tokio::spawn(async move {
            let mut buf: Vec<Row> = Vec::new();
            while let Some(first) = rx.recv().await {
                buf.push(first);
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                while let Ok(r) = rx.try_recv() {
                    if buf.len() < 5000 {
                        buf.push(r);
                    }
                }
                for chunk in buf.chunks(200) {
                    let mut sql = String::from("INSERT INTO telemetry_events (event_type, subject, outcome, duration_ms, meta) VALUES ");
                    let mut params: Vec<P> = Vec::with_capacity(chunk.len() * 5);
                    for (i, r) in chunk.iter().enumerate() {
                        let b = i * 5;
                        if i > 0 {
                            sql.push(',');
                        }
                        sql.push_str(&format!("(${},${},${},${},${})", b + 1, b + 2, b + 3, b + 4, b + 5));
                        params.extend([
                            P::Text(crate::util::cut(&r.event_type, 40)),
                            r.subject.as_deref().map(|s| crate::util::cut(s, 200)).into(),
                            r.outcome.as_deref().map(|s| crate::util::cut(s, 40)).into(),
                            r.duration_ms.into(),
                            r.meta.as_ref().map(|m| P::Text(m.to_string())).unwrap_or(P::Null),
                        ]);
                    }
                    if let Err(e) = flush_db.exec(&sql, &params).await {
                        println!("[nyxframe] telemetry.record failed: {e}");
                    }
                }
                buf.clear();
            }
        });
        Self { enabled, tx, mem: Mutex::new(Mem { since: crate::util::now(), ..Default::default() }), db }
    }

    /// Durable event row (fire-and-forget).
    pub fn record(&self, event_type: &str, subject: Option<&str>, outcome: Option<&str>, duration_ms: Option<i64>, meta: Option<Value>) {
        if !self.enabled {
            return;
        }
        let _ = self.tx.send(Row {
            event_type: event_type.to_string(),
            subject: subject.map(str::to_string),
            outcome: outcome.map(str::to_string),
            duration_ms,
            meta,
        });
    }

    pub async fn recent_events(&self, event_type: Option<&str>, limit: i64) -> Vec<Value> {
        let limit = limit.clamp(1, 200);
        match event_type.filter(|t| !t.is_empty()) {
            Some(t) => self.db.all("SELECT id, event_type, subject, outcome, duration_ms, meta, created_at FROM telemetry_events WHERE event_type=$1 ORDER BY id DESC LIMIT $2", &[t.into(), limit.into()]).await,
            None => self.db.all("SELECT id, event_type, subject, outcome, duration_ms, meta, created_at FROM telemetry_events ORDER BY id DESC LIMIT $1", &[limit.into()]).await,
        }
    }

    pub fn record_request(&self, method: &str, pattern: &str, status: u16, duration_ms: f64) {
        if !self.enabled {
            return;
        }
        let mut m = self.mem.lock().unwrap();
        let now = crate::util::now();
        if now - m.since > REQUEST_STATS_RESET_SECONDS {
            m.requests.clear();
            m.since = now;
        }
        let b = m.requests.entry(format!("{method} {pattern}")).or_default();
        b.count += 1;
        b.total_ms += duration_ms;
        b.max_ms = b.max_ms.max(duration_ms);
        if status >= 400 {
            b.error_count += 1;
        }
        b.samples.push_back(duration_ms);
        if b.samples.len() > SAMPLE_CAP {
            b.samples.pop_front();
        }
    }

    /// Last-run snapshot; persists a row only on failure or when `summary` is given.
    pub fn job_result(&self, name: &str, ok: bool, duration_ms: i64, summary: Option<Value>) {
        self.mem.lock().unwrap().jobs.insert(name.into(), json!({ "ok": ok, "duration_ms": duration_ms, "summary": summary, "at": crate::util::now() }));
        if !ok || summary.is_some() {
            self.record("job", Some(name), Some(if ok { "success" } else { "error" }), Some(duration_ms), summary);
        }
    }

    pub fn count(&self, name: &str, n: i64) {
        let mut m = self.mem.lock().unwrap();
        let cur = m.counters.get(name).and_then(Value::as_i64).unwrap_or(0);
        m.counters.insert(name.into(), json!(cur + n));
    }

    pub fn snapshot(&self) -> Value {
        let m = self.mem.lock().unwrap();
        let mut stats: Vec<Value> = m
            .requests
            .iter()
            .map(|(route, b)| {
                let mut s: Vec<f64> = b.samples.iter().copied().collect();
                s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
                let p95 = if s.is_empty() { 0.0 } else { s[((0.95 * s.len() as f64).ceil() as usize).max(1) - 1] };
                json!({
                    "route": route,
                    "count": b.count,
                    "error_count": b.error_count,
                    "avg_ms": if b.count > 0 { (b.total_ms / b.count as f64).floor() as i64 } else { 0 },
                    "p95_ms": p95.floor() as i64,
                    "max_ms": b.max_ms.floor() as i64,
                })
            })
            .collect();
        stats.sort_by_key(|v| -v["count"].as_i64().unwrap_or(0));
        json!({ "request_stats": stats, "request_stats_since": m.since, "jobs": m.jobs, "counters": m.counters })
    }

    /// Retention pruner (every 6h).
    pub fn start_pruner(self: &Arc<Self>, retention_days: i64) {
        if !self.enabled {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            loop {
                let sql = format!("DELETE FROM telemetry_events WHERE created_at < now() - interval '{} days'", retention_days.max(1));
                if let Err(e) = me.db.exec(&sql, &[]).await {
                    println!("[nyxframe] telemetry pruner error: {e}");
                }
                tokio::time::sleep(std::time::Duration::from_secs(21600)).await;
            }
        });
    }
}

