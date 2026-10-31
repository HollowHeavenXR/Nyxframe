//! "My Other Projects": latest IPA from a (private) GitHub release via `gh`, cached on disk.

use crate::http::{R, Reply, Req};
use crate::serve::file_reply;

async fn latest_tag(repo: &str) -> Option<String> {
    let out = tokio::process::Command::new("gh").args(["release", "list", "--repo", repo, "--limit", "1", "--json", "tagName", "-q", ".[0].tagName"]).stderr(std::process::Stdio::null()).output().await.ok()?;
    let t = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!t.is_empty()).then_some(t)
}

async fn latest_ipa(req: Req, repo: &str, key: &str, display: &str) -> R<Reply> {
    req.app.rate_check(&format!("project_download:{}", req.client_ip), 10, 3600).await?;
    let tag = latest_tag(repo).await.ok_or_else(|| Reply::err(502, format!("Could not reach GitHub to check the latest {display} release. Try again shortly.")))?;
    let dir = format!("{}/_project_downloads", req.app.settings.uploads_dir);
    let _ = tokio::fs::create_dir_all(&dir).await;
    let safe: String = tag.chars().map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' }).collect();
    let path = format!("{dir}/{key}_{safe}.ipa");
    let headers = [("Content-Disposition", format!("attachment; filename=\"{display}-{safe}.ipa\"")), ("Cache-Control", "private, max-age=0, no-cache".to_string())];
    if crate::media_files::exists(&path) {
        return file_reply(&req, &path, "application/octet-stream", &headers, false).await;
    }
    let pending = format!("{path}.pending");
    let fresh = tokio::fs::read_to_string(&pending).await.ok().and_then(|t| t.trim().parse::<i64>().ok()).is_some_and(|t| crate::util::now() - t < 20);
    if !fresh {
        let _ = tokio::fs::write(&pending, crate::util::now().to_string()).await;
        let (repo, tag, path, pending) = (repo.to_string(), tag.clone(), path.clone(), pending.clone());
        tokio::spawn(async move {
            let tmp = format!("{path}.tmp.{}", rand::random_range(100000..999999));
            let ok = tokio::process::Command::new("gh").args(["release", "download", &tag, "--repo", &repo, "--pattern", "*.ipa", "-O", &tmp, "--clobber"]).status().await.is_ok_and(|s| s.success());
            if ok {
                let _ = tokio::fs::rename(&tmp, &path).await;
            }
            let _ = tokio::fs::remove_file(&tmp).await;
            let _ = tokio::fs::remove_file(&pending).await;
        });
    }
    for _ in 0..40 {
        if crate::media_files::exists(&path) {
            return file_reply(&req, &path, "application/octet-stream", &headers, false).await;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    Err(Reply::err(503, format!("Still fetching the latest {display} build from GitHub -- try again in a moment.")))
}

pub async fn lumisound(req: Req) -> R<Reply> {
    latest_ipa(req, "HollowHeavenXR/Lumisound", "lumisound", "Lumisound").await
}

pub async fn nyxframe(req: Req) -> R<Reply> {
    latest_ipa(req, "HollowHeavenXR/Nyxframe", "nyxframe", "Nyxframe").await
}
