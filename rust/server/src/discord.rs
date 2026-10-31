//! Discord bot DMs (port of discord_bot.lua) and fire-and-forget webhook
//! embeds (port of discord_webhook.lua).

use crate::app::App;
use serde_json::{Value, json};
use std::time::Duration;

const API: &str = "https://discord.com/api/v10";
const UA: &str = "NyxframeBot (https://github.com/HollowHeavenXR/Nyxframe, 1.0)";

pub fn bot_enabled(app: &App) -> bool {
    !app.settings.discord_bot_token.is_empty()
}

async fn api(app: &App, method: reqwest::Method, path: &str, body: Option<Value>) -> Option<(u16, Value)> {
    let mut r = app
        .http
        .request(method, format!("{API}{path}"))
        .header("Authorization", format!("Bot {}", app.settings.discord_bot_token))
        .header("User-Agent", UA)
        .timeout(Duration::from_secs(12));
    if let Some(b) = body {
        r = r.json(&b);
    }
    let resp = r.send().await.ok()?;
    let status = resp.status().as_u16();
    let v = resp.json::<Value>().await.ok().filter(Value::is_object).unwrap_or_else(|| json!({}));
    Some((status, v))
}

pub async fn send_dm(app: &App, user_id: &str, content: &str) -> Result<(), String> {
    if !bot_enabled(app) {
        return Err("Discord verification isn't configured on this server yet.".into());
    }
    if user_id.is_empty() || !user_id.chars().all(|c| c.is_ascii_digit()) {
        return Err("That doesn't look like a valid Discord User ID (numbers only).".into());
    }
    let Some((s1, channel)) = api(app, reqwest::Method::POST, "/users/@me/channels", Some(json!({ "recipient_id": user_id }))).await else {
        return Err("Could not reach Discord: nil".into());
    };
    let Some(cid) = channel.get("id").and_then(Value::as_str).map(str::to_string) else {
        return Err(format!("Could not reach Discord: {s1}"));
    };
    if !(200..300).contains(&s1) {
        return Err("Could not open a DM with that account -- make sure you share a server with the bot and allow direct messages from server members.".into());
    }
    match api(app, reqwest::Method::POST, &format!("/channels/{cid}/messages"), Some(json!({ "content": content }))).await {
        Some((s, _)) if (200..300).contains(&s) => Ok(()),
        Some((s, v)) => Err(match v.get("message").and_then(Value::as_str) {
            Some(m) => format!("Discord rejected the message: {m}"),
            None => format!("Discord rejected the message: {s}"),
        }),
        None => Err("Discord rejected the message: nil".into()),
    }
}

pub async fn get_user(app: &App, user_id: &str) -> Option<String> {
    if !bot_enabled(app) {
        return None;
    }
    let (s, v) = api(app, reqwest::Method::GET, &format!("/users/{user_id}"), None).await?;
    if !(200..300).contains(&s) {
        return None;
    }
    v.get("global_name").and_then(Value::as_str).or_else(|| v.get("username").and_then(Value::as_str)).map(str::to_string)
}

pub fn webhook_valid(url: &str) -> bool {
    url.starts_with("https://discord.com/api/webhooks/") || url.starts_with("https://discordapp.com/api/webhooks/")
}

/// POST {embeds} in the background, retrying transient failures.
pub fn webhook_send(app: &App, url: &str, embeds: Value) {
    if !webhook_valid(url) {
        return;
    }
    let (http, url) = (app.http.clone(), url.to_string());
    tokio::spawn(async move {
        let body = json!({ "embeds": embeds });
        for attempt in 0..3u32 {
            match http.post(&url).json(&body).timeout(Duration::from_secs(15)).send().await {
                Ok(r) if r.status().is_success() => return,
                Ok(r) if r.status().as_u16() == 429 || r.status().is_server_error() => {}
                Ok(r) => {
                    println!("[nyxframe] Discord webhook delivery failed: Discord webhook responded with HTTP {}", r.status().as_u16());
                    return;
                }
                Err(e) if attempt == 2 => {
                    println!("[nyxframe] Discord webhook delivery failed: {e}");
                    return;
                }
                Err(_) => {}
            }
            tokio::time::sleep(Duration::from_millis(500 * 2u64.pow(attempt))).await;
        }
    });
}
