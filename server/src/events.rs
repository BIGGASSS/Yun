use crate::{ApiError, AppState, auth::Auth, now, valid_id};
use axum::{
    Json,
    extract::{Query, State},
};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use std::collections::HashMap;

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
    let mut unique = HashMap::new();
    let mut sessions = HashMap::new();
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
        if unique
            .insert(event.id.as_str(), event)
            .is_some_and(|old| old != event)
        {
            return Err(ApiError::conflict(
                "event ID already exists with different payload",
            ));
        }
        if sessions
            .insert((&event.device_id, &event.session_id), &event.track_id)
            .is_some_and(|old| old != &event.track_id)
        {
            return Err(ApiError::bad("a device/session must refer to one track"));
        }
    }
    let data = serde_json::to_string(&unique.values().collect::<Vec<_>>())
        .map_err(|_| ApiError::bad("invalid events"))?;
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let existing: Vec<Event> = sqlx::query_as("SELECT e.id,e.device_id,e.session_id,e.track_id,e.started_at,e.ended_at,e.listened_ms,e.timezone_offset_minutes FROM json_each(?) j JOIN listening_events e ON e.user_id=? AND e.id=json_extract(j.value,'$.id')")
        .bind(&data).bind(&auth.user).fetch_all(&mut *tx).await?;
    for event in existing {
        if unique
            .get(event.id.as_str())
            .is_some_and(|incoming| **incoming != event)
        {
            return Err(ApiError::conflict(
                "event ID already exists with different payload",
            ));
        }
    }
    // Validate only requested IDs, including owned tombstones for delayed offline
    // events. Session lookups stop at one indexed historical event.
    let unknown: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM json_each(?1) j WHERE NOT EXISTS(SELECT 1 FROM devices d WHERE d.user_id=?2 AND d.id=json_extract(j.value,'$.device_id')) OR NOT EXISTS(SELECT 1 FROM tracks t WHERE t.user_id=?2 AND t.id=json_extract(j.value,'$.track_id')))")
        .bind(&data).bind(&auth.user).fetch_one(&mut *tx).await?;
    if unknown {
        return Err(ApiError::bad("unknown device or track"));
    }
    let mismatch: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM json_each(?1) j WHERE (SELECT track_id FROM listening_events e WHERE e.user_id=?2 AND e.device_id=json_extract(j.value,'$.device_id') AND e.session_id=json_extract(j.value,'$.session_id') LIMIT 1) != json_extract(j.value,'$.track_id'))")
        .bind(&data).bind(&auth.user).fetch_one(&mut *tx).await?;
    if mismatch {
        return Err(ApiError::bad("a device/session must refer to one track"));
    }
    sqlx::query("INSERT INTO listening_events(user_id,id,device_id,session_id,track_id,started_at,ended_at,listened_ms,timezone_offset_minutes) SELECT ?2,json_extract(value,'$.id'),json_extract(value,'$.device_id'),json_extract(value,'$.session_id'),json_extract(value,'$.track_id'),json_extract(value,'$.started_at'),json_extract(value,'$.ended_at'),json_extract(value,'$.listened_ms'),json_extract(value,'$.timezone_offset_minutes') FROM json_each(?1) j WHERE NOT EXISTS(SELECT 1 FROM listening_events e WHERE e.user_id=?2 AND e.id=json_extract(j.value,'$.id'))")
        .bind(&data).bind(&auth.user).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(Ack {
        acknowledged_ids: input.events.into_iter().map(|e| e.id).collect(),
    }))
}
#[derive(Deserialize)]
pub(crate) struct Range {
    from: Option<i64>,
    to: Option<i64>,
}
#[derive(Serialize, Deserialize)]
struct TopTrack {
    id: String,
    title: String,
    artist: String,
    listened_ms: i64,
    play_count: i64,
}
#[derive(Serialize, Deserialize)]
struct TopArtist {
    name: String,
    listened_ms: i64,
    play_count: i64,
}
#[derive(Serialize, Deserialize)]
struct TopAlbum {
    name: String,
    artist: String,
    listened_ms: i64,
    play_count: i64,
}
#[derive(Serialize, Deserialize)]
struct History {
    session_id: String,
    track_id: String,
    title: String,
    artist: String,
    started_at: i64,
    listened_ms: i64,
    counted_play: bool,
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Stats {
    listened_ms: i64,
    play_count: i64,
    top_tracks: Vec<TopTrack>,
    top_artists: Vec<TopArtist>,
    top_albums: Vec<TopAlbum>,
    history: Vec<History>,
}
// First use the range index to find candidate sessions. Only their complete
// histories enter the window. The date filter MUST stay after the window so
// offline insertion/reordering and threshold crossings across dates are stable.
// MATERIALIZED shares selected rows across all five aggregates in one statement;
// no pooled-connection temporary table or repeated all-history window is needed.
const STATS: &str = "WITH candidates AS MATERIALIZED (
 SELECT DISTINCT device_id,session_id FROM listening_events WHERE user_id=?1 AND started_at>=?2 AND started_at<?3
), cumulative AS (
 SELECT e.*,t.title,t.artist,t.album,CASE WHEN t.album_artist='' THEN t.artist ELSE t.album_artist END AS album_artist,
 MIN(30000,MAX(1,t.duration_ms/2)) AS threshold,
 SUM(e.listened_ms) OVER (PARTITION BY e.device_id,e.session_id ORDER BY e.started_at,e.ended_at,e.id ROWS UNBOUNDED PRECEDING) AS running
 FROM candidates c JOIN listening_events e ON e.user_id=?1 AND e.device_id=c.device_id AND e.session_id=c.session_id
 JOIN tracks t ON t.id=e.track_id AND t.user_id=e.user_id
), selected AS MATERIALIZED (
 SELECT *,CASE WHEN running>=threshold AND running-listened_ms<threshold THEN 1 ELSE 0 END AS counted_play
 FROM cumulative WHERE started_at>=?2 AND started_at<?3
)
SELECT json_object(
 'listened_ms',COALESCE(SUM(listened_ms),0),'play_count',COALESCE(SUM(counted_play),0),
 'top_tracks',(SELECT json_group_array(json_object('id',track_id,'title',title,'artist',artist,'listened_ms',ms,'play_count',plays)) FROM (
 SELECT track_id,title,artist,SUM(listened_ms) ms,SUM(counted_play) plays FROM selected GROUP BY track_id ORDER BY ms DESC,plays DESC,track_id LIMIT 50)),
 'top_artists',(SELECT json_group_array(json_object('name',artist,'listened_ms',ms,'play_count',plays)) FROM (
 SELECT artist,SUM(listened_ms) ms,SUM(counted_play) plays FROM selected GROUP BY artist ORDER BY ms DESC,plays DESC,artist LIMIT 50)),
 'top_albums',(SELECT json_group_array(json_object('name',album,'artist',album_artist,'listened_ms',ms,'play_count',plays)) FROM (
 SELECT album,album_artist,SUM(listened_ms) ms,SUM(counted_play) plays FROM selected GROUP BY album,album_artist ORDER BY ms DESC,plays DESC,album,album_artist LIMIT 50)),
 'history',(SELECT json_group_array(json_object('session_id',session_id,'track_id',track_id,'title',title,'artist',artist,'started_at',start,'listened_ms',ms,'counted_play',json(CASE WHEN plays=1 THEN 'true' ELSE 'false' END))) FROM (
 SELECT device_id,session_id,track_id,title,artist,MIN(started_at) start,SUM(listened_ms) ms,MAX(counted_play) plays FROM selected GROUP BY device_id,session_id ORDER BY start DESC,device_id,session_id LIMIT 100))
) FROM selected";

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
    let result: String = sqlx::query_scalar(STATS)
        .bind(&auth.user)
        .bind(from)
        .bind(to)
        .fetch_one(&state.0.pool)
        .await?;
    Ok(Json(serde_json::from_str(&result).map_err(|_| {
        ApiError::new(
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            "invalid statistics result",
        )
    })?))
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn stats_plan_materializes_once_and_uses_range_and_session_indexes() {
        let dir = tempfile::tempdir().unwrap();
        let state = crate::AppState::open(crate::Config::new(dir.path()))
            .await
            .unwrap();
        let rows = sqlx::query(&format!("EXPLAIN QUERY PLAN {}", super::STATS))
            .bind("u")
            .bind(100)
            .bind(200)
            .fetch_all(&state.0.pool)
            .await
            .unwrap();
        use sqlx::Row;
        let plan: Vec<String> = rows.iter().map(|r| r.get("detail")).collect();
        assert_eq!(
            plan.iter()
                .filter(|s| s.contains("MATERIALIZE selected"))
                .count(),
            1,
            "{plan:?}"
        );
        assert!(plan.iter().any(|s| s.contains("events_range")), "{plan:?}");
        assert!(
            plan.iter().any(|s| s.contains("events_session")
                && s.contains("device_id=?")
                && s.contains("session_id=?")),
            "{plan:?}"
        );
    }
}
