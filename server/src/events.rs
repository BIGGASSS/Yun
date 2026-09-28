use crate::{ApiError, AppState, auth::Auth, now, valid_id};
use axum::{
    Json,
    extract::{Query, State},
};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

#[derive(Deserialize, Serialize, FromRow, PartialEq, Eq, Debug)]
#[serde(deny_unknown_fields)]
pub(crate) struct Event {
    id: String,
    device_id: String,
    session_id: String,
    track_id: String,
    started_at: i64,
    ended_at: i64,
    listened_ms: i64,
    timezone_offset_minutes: i64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Batch {
    events: Vec<Event>,
}
#[derive(Serialize)]
pub(crate) struct Ack {
    acknowledged_ids: Vec<String>,
}
pub(crate) async fn ingest(
    State(state): State<AppState>,
    auth: Auth,
    Json(input): Json<Batch>,
) -> Result<Json<Ack>, ApiError> {
    if input.events.len() > 500 {
        return Err(ApiError::bad("maximum 500 events per batch"));
    }
    let latest = now() + 120_000;
    for event in &input.events {
        for id in [
            &event.id,
            &event.device_id,
            &event.session_id,
            &event.track_id,
        ] {
            valid_id(id)?;
        }
        if event.started_at < 0
            || event.ended_at <= event.started_at
            || event.ended_at > latest
            || event.ended_at - event.started_at > 60_000
            || event.listened_ms < 0
            || event.listened_ms > event.ended_at - event.started_at + 2000
            || !(-840..=840).contains(&event.timezone_offset_minutes)
        {
            return Err(ApiError::bad(
                "invalid listening segment timestamps, duration, or timezone",
            ));
        }
    }
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let mut acknowledged_ids = Vec::with_capacity(input.events.len());
    for event in input.events {
        let existing: Option<Event>=sqlx::query_as("SELECT id,device_id,session_id,track_id,started_at,ended_at,listened_ms,timezone_offset_minutes FROM listening_events WHERE user_id=? AND id=?").bind(&auth.user).bind(&event.id).fetch_optional(&mut *tx).await?;
        if let Some(existing) = existing {
            if existing != event {
                return Err(ApiError::conflict(
                    "event ID already exists with different payload",
                ));
            }
            acknowledged_ids.push(event.id);
            continue;
        }
        let device: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE user_id=? AND id=?)")
                .bind(&auth.user)
                .bind(&event.device_id)
                .fetch_one(&mut *tx)
                .await?;
        // Deliberately includes owned deleted tracks: offline events can arrive later.
        let track: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM tracks WHERE user_id=? AND id=?)")
                .bind(&auth.user)
                .bind(&event.track_id)
                .fetch_one(&mut *tx)
                .await?;
        if !device || !track {
            return Err(ApiError::bad("unknown device or track"));
        }
        let previous_track: Option<String>=sqlx::query_scalar("SELECT track_id FROM listening_events WHERE user_id=? AND device_id=? AND session_id=? LIMIT 1").bind(&auth.user).bind(&event.device_id).bind(&event.session_id).fetch_optional(&mut *tx).await?;
        if previous_track.is_some_and(|v| v != event.track_id) {
            return Err(ApiError::bad("a device/session must refer to one track"));
        }
        sqlx::query("INSERT INTO listening_events(user_id,id,device_id,session_id,track_id,started_at,ended_at,listened_ms,timezone_offset_minutes) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&auth.user).bind(&event.id).bind(event.device_id).bind(event.session_id).bind(event.track_id).bind(event.started_at).bind(event.ended_at).bind(event.listened_ms).bind(event.timezone_offset_minutes).execute(&mut *tx).await?;
        acknowledged_ids.push(event.id);
    }
    tx.commit().await?;
    Ok(Json(Ack { acknowledged_ids }))
}
#[derive(Deserialize)]
pub(crate) struct Range {
    from: Option<i64>,
    to: Option<i64>,
}
#[derive(Serialize, FromRow)]
struct Totals {
    listened_ms: i64,
    play_count: i64,
}
#[derive(Serialize, FromRow)]
struct TopTrack {
    id: String,
    title: String,
    artist: String,
    listened_ms: i64,
    play_count: i64,
}
#[derive(Serialize, FromRow)]
struct TopArtist {
    name: String,
    listened_ms: i64,
    play_count: i64,
}
#[derive(Serialize, FromRow)]
struct TopAlbum {
    name: String,
    artist: String,
    listened_ms: i64,
    play_count: i64,
}
#[derive(Serialize, FromRow)]
struct History {
    session_id: String,
    track_id: String,
    title: String,
    artist: String,
    started_at: i64,
    listened_ms: i64,
    counted_play: bool,
}
#[derive(Serialize)]
pub(crate) struct Stats {
    listened_ms: i64,
    play_count: i64,
    top_tracks: Vec<TopTrack>,
    top_artists: Vec<TopArtist>,
    top_albums: Vec<TopAlbum>,
    history: Vec<History>,
}
// Compute threshold crossings over the *entire* session before applying the time
// range. A session cannot acquire a second counted play by querying another day.
// Ordered by event time, not ingestion time: offline reordering is deterministic.
const BASE: &str = "WITH cumulative AS (
 SELECT e.*,t.title,t.artist,t.album,CASE WHEN t.album_artist='' THEN t.artist ELSE t.album_artist END AS album_artist,
 MIN(30000,MAX(1,t.duration_ms/2)) AS threshold,
 SUM(e.listened_ms) OVER (PARTITION BY e.device_id,e.session_id ORDER BY e.started_at,e.ended_at,e.id ROWS UNBOUNDED PRECEDING) AS running
 FROM listening_events e JOIN tracks t ON t.id=e.track_id AND t.user_id=e.user_id WHERE e.user_id=?
), counted AS (
 SELECT *,CASE WHEN running>=threshold AND running-listened_ms<threshold THEN 1 ELSE 0 END AS counted_play FROM cumulative
), selected AS (SELECT * FROM counted WHERE started_at>=? AND started_at<?) ";
pub(crate) async fn stats(
    State(state): State<AppState>,
    auth: Auth,
    Query(range): Query<Range>,
) -> Result<Json<Stats>, ApiError> {
    let from = range.from.unwrap_or(0);
    let to = range.to.unwrap_or(i64::MAX);
    if from < 0 || to < 0 || from > to {
        return Err(ApiError::bad("invalid stats range"));
    }
    let mut tx = state.0.pool.begin().await?;
    let totals: Totals=sqlx::query_as(&format!("{BASE} SELECT COALESCE(SUM(listened_ms),0) AS listened_ms,COALESCE(SUM(counted_play),0) AS play_count FROM selected"))
        .bind(&auth.user).bind(from).bind(to).fetch_one(&mut *tx).await?;
    let top_tracks=sqlx::query_as(&format!("{BASE} SELECT track_id AS id,title,artist,SUM(listened_ms) AS listened_ms,SUM(counted_play) AS play_count FROM selected GROUP BY track_id ORDER BY listened_ms DESC,play_count DESC,track_id LIMIT 50"))
        .bind(&auth.user).bind(from).bind(to).fetch_all(&mut *tx).await?;
    let top_artists=sqlx::query_as(&format!("{BASE} SELECT artist AS name,SUM(listened_ms) AS listened_ms,SUM(counted_play) AS play_count FROM selected GROUP BY artist ORDER BY listened_ms DESC,play_count DESC,artist LIMIT 50"))
        .bind(&auth.user).bind(from).bind(to).fetch_all(&mut *tx).await?;
    let top_albums=sqlx::query_as(&format!("{BASE} SELECT album AS name,album_artist AS artist,SUM(listened_ms) AS listened_ms,SUM(counted_play) AS play_count FROM selected GROUP BY album,album_artist ORDER BY listened_ms DESC,play_count DESC,album,album_artist LIMIT 50"))
        .bind(&auth.user).bind(from).bind(to).fetch_all(&mut *tx).await?;
    let history=sqlx::query_as(&format!("{BASE} SELECT session_id,track_id,title,artist,MIN(started_at) AS started_at,SUM(listened_ms) AS listened_ms,MAX(counted_play) AS counted_play FROM selected GROUP BY device_id,session_id ORDER BY started_at DESC,device_id,session_id LIMIT 100"))
        .bind(auth.user).bind(from).bind(to).fetch_all(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(Stats {
        listened_ms: totals.listened_ms,
        play_count: totals.play_count,
        top_tracks,
        top_artists,
        top_albums,
        history,
    }))
}
