//! Nyxframe (Rust): the gallery's JSON API, media byte serving (files,
//! thumbnails, previews, HLS), uploads and background jobs.
#![recursion_limit = "512"]

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod ai;
mod app;
mod auth;
mod config;
mod db;
mod discord;
mod extras;
mod http;
mod jobs;
mod media;
mod media_files;
mod ratelimit;
mod routes;
mod serve;
mod sniff;
mod telemetry;
mod totp;
mod upload;
mod user_settings;
mod util;
mod video;
mod webpush;

use axum::Router;
use axum::routing::{delete, get, patch, post};
use routes::{account as acc, admin as adm, ai_routes as air, browse as brw, collections as col, diag, feeds, media_actions as ma, messages as msg, notify as ntf, projects, site, social as soc};
use std::net::SocketAddr;

fn api_routes() -> Router<app::AppRef> {
    Router::new()
        .route("/api/health", get(acc::health))
        .route("/api/live/checks", get(acc::live_checks))
        .route("/api/status", get(acc::public_status))
        .route("/api/auth/register", post(acc::register))
        .route("/api/auth/login", post(acc::login))
        .route("/api/auth/2fa/verify", post(acc::verify_2fa))
        .route("/api/auth/logout", post(acc::logout))
        .route("/api/me", get(acc::me))
        .route("/api/me/profile", patch(acc::update_profile))
        .route("/api/me/settings", patch(acc::update_settings))
        .route("/api/me/avatar", post(acc::update_avatar))
        .route("/api/me/age-verification", post(acc::verify_age))
        .route("/api/me/password", post(acc::change_password))
        .route("/api/me/export", get(acc::export_account))
        .route("/api/me/discord/verify/status", get(acc::discord_verify_status))
        .route("/api/me/discord/verify/start", post(acc::discord_verify_start))
        .route("/api/me/discord/verify/confirm", post(acc::discord_verify_confirm))
        .route("/api/me/discord/unlink", post(acc::discord_unlink))
        .route("/api/appearance/presets", get(acc::appearance_presets))
        .route("/api/me/2fa/status", get(acc::totp_status))
        .route("/api/me/2fa/enroll", post(acc::totp_enroll))
        .route("/api/me/2fa/confirm", post(acc::totp_confirm))
        .route("/api/me/2fa/disable", post(acc::totp_disable))
        .route("/api/me/api-keys", get(acc::list_api_keys).post(acc::create_api_key))
        .route("/api/me/api-keys/{key_id}", delete(acc::revoke_api_key))
        .route("/api/me/media", get(brw::my_media))
        .route("/api/me/on-this-day", get(brw::on_this_day))
        .route("/api/me/stats", get(brw::creator_stats))
        .route("/api/me/year-recap", get(brw::year_recap))
        .route("/api/me/likes", get(brw::feed_liked))
        .route("/api/feed/following", get(brw::feed_following))
        .route("/api/feed/signal", get(brw::feed_signal))
        .route("/api/feed/for-you", get(brw::feed_for_you))
        .route("/api/categories", get(brw::list_categories).post(brw::create_category))
        .route("/api/leaderboard", get(brw::leaderboard))
        .route("/api/media/trending", get(brw::media_trending))
        .route("/api/media/bulk", post(ma::bulk_edit))
        .route("/api/media/bulk-delete", post(ma::bulk_delete))
        .route("/api/media/random", get(ma::media_random))
        .route("/api/me/continue-watching", get(ma::continue_watching))
        .route("/api/media/{media_id}", get(ma::media_detail).patch(ma::update_media).delete(ma::delete_media))
        .route("/api/media/{media_id}/like", post(ma::like_media))
        .route("/api/media/{media_id}/viewing", post(ma::viewing_heartbeat))
        .route("/api/media/{media_id}/bookmark", post(ma::bookmark_media))
        .route("/api/media/{media_id}/comments", post(ma::add_comment))
        .route("/api/media/{media_id}/react", post(ma::react_to_media))
        .route("/api/media/{media_id}/similar", get(ma::similar_media))
        .route("/api/media/{media_id}/history", get(ma::edit_history))
        .route("/api/media/{media_id}/controls", patch(ma::set_controls))
        .route("/api/media/{media_id}/restore", post(ma::restore_media))
        .route("/api/media/{media_id}/report", post(ma::report_media))
        .route("/api/media/{media_id}/watch-progress", get(ma::watch_progress).post(ma::save_watch_progress))
        .route("/api/me/personal-tags", get(ma::my_personal_tags))
        .route("/api/media/{media_id}/personal-tags", post(ma::add_personal_tag))
        .route("/api/media/{media_id}/personal-tags/{tag}", delete(ma::remove_personal_tag))
        .route("/api/comments/{comment_id}", delete(ma::delete_comment))
        .route("/api/comments/{comment_id}/react", post(ma::react_to_comment))
        .route("/api/me/memories", get(ma::my_memories))
        .route("/api/notifications", get(ntf::list))
        .route("/api/notifications/unread-count", get(ntf::unread_count))
        .route("/api/notifications/read-all", post(ntf::mark_all_read))
        .route("/api/notifications/{notification_id}/read", post(ntf::mark_read))
        .route("/api/push/vapid-public-key", get(ntf::vapid_public_key))
        .route("/api/push/subscribe", post(ntf::subscribe))
        .route("/api/push/unsubscribe", post(ntf::unsubscribe))
        .route("/api/saved-searches", get(ntf::list_saved).post(ntf::create_saved))
        .route("/api/saved-searches/{search_id}", delete(ntf::delete_saved))
        .route("/api/saved-searches/{search_id}/mute", patch(ntf::mute_saved))
        .route("/api/tags", get(site::tag_cloud))
        .route("/api/site/announcement", get(site::announcement))
        .route("/api/site/background", get(site::background))
        .route("/api/messages/threads", get(msg::threads))
        .route("/api/messages/{user_id}", get(msg::direct_messages).post(msg::send_direct))
        .route("/api/threads", get(msg::list_groups).post(msg::create_group))
        .route("/api/threads/{group_id}/messages", get(msg::group_messages).post(msg::send_group))
        .route("/api/collections/suggestions", get(col::suggestions))
        .route("/api/collections", get(col::list).post(col::create))
        .route("/api/collections/{collection_id}", get(col::detail))
        .route("/api/collections/{collection_id}/items", post(col::save_item))
        .route("/api/users/search", get(soc::search_users))
        .route("/api/users/suggested", get(soc::suggested_users))
        .route("/api/users/{username}/profile", get(soc::profile_page))
        .route("/api/users/{username}", get(soc::public_profile))
        .route("/api/users/{user_id}/follow", post(soc::follow))
        .route("/api/users/{user_id}/follow-mute", patch(soc::follow_mute))
        .route("/api/users/{user_id}/friend-request", post(soc::friend_request))
        .route("/api/friends/requests", get(soc::friend_requests))
        .route("/api/friends/requests/{request_id}", post(soc::respond_friend_request))
        .route("/api/me/friends", get(soc::my_friends))
        .route("/api/users/{user_id}/followers", get(soc::followers))
        .route("/api/users/{user_id}/following", get(soc::following))
        .route("/api/users/{user_id}/friends", get(soc::user_friends))
        .route("/api/users/{user_id}/block", post(soc::block))
        .route("/api/me/blocks", get(soc::my_blocks))
        .route("/api/me/media/picker", get(serve::media_picker))
        .route("/api/media/download-batch", post(serve::download_batch))
        .route("/api/media/upload/thumbnail", post(serve::stage_thumbnail))
        .route("/api/media/{media_id}/thumbnail", post(serve::set_thumbnail).delete(serve::clear_thumbnail))
        .route("/api/media/{media_id}/thumb", get(serve::thumb))
        .route("/api/media/{media_id}/thumb.webp", get(serve::thumb))
        .route("/api/media/{media_id}/preview", get(serve::preview))
        .route("/api/media/{media_id}/preview.webp", get(serve::preview))
        .route("/api/media/{media_id}/file", get(serve::file))
        .route("/api/media/{media_id}/download", get(serve::download))
        .route("/api/media/{media_id}/hls/master.m3u8", get(serve::hls_master))
        .route("/api/media/{media_id}/hls/{quality}/playlist.m3u8", get(serve::hls_playlist))
        .route("/api/media/{media_id}/hls/{quality}/master.m3u8", get(extras::quality_master))
        .route("/api/media/{media_id}/hls/{quality}/{segment}", get(serve::hls_segment))
        .route("/api/media/{media_id}/playback-extras", get(extras::playback_extras))
        .route("/api/media/{media_id}/sprite.jpg", get(extras::sprite_sheet))
        .route("/api/media/{media_id}/sprite.vtt", get(extras::sprite_vtt))
        .route("/api/media/{media_id}/captions/en.vtt", get(extras::captions))
        .route("/api/media/{media_id}/captions/subs.m3u8", get(extras::captions_playlist))
        .route("/api/users/{user_id}/avatar", get(serve::avatar))
        .route("/api/collections/{collection_id}/download", get(serve::download_collection))
        .route("/api/media", get(brw::list_media).post(upload::upload_media))
        .route("/api/media/analyze", post(upload::analyze_media))
        .route("/api/media/upload/init", post(upload::chunk_init))
        .route("/api/media/upload/chunk", post(upload::chunk_append))
        .route("/api/media/upload/finish", post(upload::chunk_finish))
        .route("/api/media/upload/job/{job_id}", get(upload::job_status))
        .route("/api/media/upload/diagnostics", post(diag::upload_diagnostic))
        .route("/api/search/visual", post(upload::visual_search))
        .route("/api/media/{media_id}/visual-similar", get(upload::visual_search_from_media))
        .route("/api/media/{media_id}/ai/train", post(air::train_media))
        .route("/api/media/{media_id}/diagnostics/load", post(diag::media_load))
        .route("/api/media/{media_id}/diagnostics/playback", post(diag::media_playback))
        .route("/api/ai/vision/status", get(air::vision_status))
        .route("/api/ai/vision/training/export", get(air::export_training))
        .route("/api/ai/vision/training", get(air::list_training))
        .route("/api/projects/lumisound/download", get(projects::lumisound))
        .route("/api/projects/nyxframe/download", get(projects::nyxframe))
        .route("/api/stats", get(adm::stats))
        .route("/api/admin/telemetry", get(adm::telemetry))
        .route("/api/admin/reports", get(adm::list_reports))
        .route("/api/admin/reports/{report_id}/resolve", post(adm::resolve_report))
        .route("/api/admin/users", get(adm::list_users))
        .route("/api/admin/users/{user_id}", get(adm::user_summary))
        .route("/api/admin/users/{user_id}/delete", post(adm::delete_user))
        .route("/api/admin/users/{user_id}/ban", post(adm::ban_user))
        .route("/api/admin/users/{user_id}/unban", post(adm::unban_user))
        .route("/api/admin/audit-log", get(adm::audit_log))
        .route("/api/admin/flagged-media", get(adm::flagged_media))
        .route("/api/admin/flagged-media/{media_id}/resolve", post(adm::resolve_flagged))
        .route("/api/admin/storage", get(adm::storage))
        .route("/api/admin/storage/purge-orphans", post(adm::purge_orphans))
        .route("/api/admin/incidents", post(adm::create_incident))
        .route("/api/admin/incidents/{incident_id}/resolve", post(adm::resolve_incident))
        .route("/api/admin/tags/{tag}/usage", get(adm::tag_usage))
        .route("/api/admin/tags/rename", post(adm::rename_tag))
        .route("/api/admin/site-settings", patch(adm::update_site_settings))
        .route("/api/admin/background-music", get(adm::admin_list_music).post(adm::admin_upload_music))
        .route("/api/admin/background-music/{track_id}", delete(adm::admin_delete_music))
        .route("/api/admin/background-music/import-playlist", post(adm::import_music_playlist))
        .route("/api/background-music", get(adm::list_music))
        .route("/api/background-music/{track_id}/file", get(adm::music_file))
        .route("/feed.xml", get(feeds::site))
        .route("/feed/me.xml", get(feeds::personal))
        .route("/feed/category/{file}", get(feeds::category))
        .route("/feed/user/{file}", get(feeds::user))
        .route("/feed/tag/{file}", get(feeds::tag))
        .route("/sitemap.xml", get(feeds::sitemap))
}

/// Non-API GETs: the built SPA (crawlers get an Open Graph preview for /media/:id).
async fn fallback(req: http::Req) -> http::R<http::Reply> {
    if req.method != axum::http::Method::GET || req.path.starts_with("/api/") {
        return Err(http::Reply::err(404, "Not found"));
    }
    if let Some(id) = req.path.strip_prefix("/media/").and_then(|i| i.parse::<i64>().ok()) {
        if routes::feeds::is_crawler(req.header("user-agent")) {
            if let Some(html) = routes::feeds::media_preview(&req, id).await {
                return Ok(http::Reply::html(html));
            }
        }
    }
    let root = format!("{}/react", req.app.settings.static_dir);
    let rel = match req.path.as_str() {
        "/favicon.ico" | "/service-worker.js" => req.path[1..].to_string(),
        p if p.starts_with("/static/react/") && !p.contains("..") => p["/static/react/".len()..].to_string(),
        _ => "index.html".into(),
    };
    let path = format!("{root}/{rel}");
    let path = if media_files::exists(&path) { path } else { format!("{root}/index.html") };
    let ctype = mime_guess::from_path(&path).first_or_octet_stream().to_string();
    let hashed = rel.starts_with("assets/") && rel.rsplit_once('-').is_some();
    let cc = if hashed { "public, max-age=31536000, immutable" } else if rel == "index.html" || rel.ends_with("service-worker.js") { "no-cache" } else { "public, max-age=300" };
    serve::file_reply(&req, &path, &ctype, &[("Cache-Control", cc.to_string())], false).await
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let settings = config::Settings::load();
    let addr: SocketAddr = format!("{}:{}", settings.host, settings.port).parse()?;
    let app = app::App::new(settings);
    // Fast-disk tier: new originals land here and are read from here first.
    if !app.settings.hot_dir.is_empty() {
        let _ = std::fs::create_dir_all(format!("{}/staging", app.settings.hot_dir));
        media_files::set_hot_root(Some(app.settings.hot_dir.clone()));
    }
    upload::configure(&app).await;
    if std::env::var("GALLERY_DISABLE_JOBS").is_err() {
        jobs::start(&app);
    }
    match app.db.one("SELECT now()::text AS now", &[]).await {
        Ok(Some(r)) => println!("[nyxframe] Postgres reachable (server time: {})", r["now"].as_str().unwrap_or("?")),
        other => println!("[nyxframe] WARNING: Postgres not reachable at startup: {:?}", other.err()),
    }
    let router = api_routes()
        .route_layer(axum::middleware::from_fn(http::tag_pattern))
        .fallback(fallback)
        .layer(axum::middleware::from_fn_with_state(app.clone(), http::middleware))
        .with_state(app.clone());
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("[nyxframe] listening on {addr}");
    axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("signal");
            tokio::select! {
                _ = term.recv() => {}
                _ = tokio::signal::ctrl_c() => {}
            }
        })
        .await?;
    Ok(())
}
