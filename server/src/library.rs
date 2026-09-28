use crate::{ApiError, AppState, auth::Auth, bump, text};
use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, SqliteConnection};

pub(crate) const TRACK_COLUMNS: &str = "id,title,artist,album,album_artist,track_number,disc_number,duration_ms,size_bytes,sha256,mime_type,(artwork_path IS NOT NULL) AS has_artwork,revision,created_at";
#[derive(Serialize, FromRow, Debug)]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub track_number: Option<i64>,
    pub disc_number: Option<i64>,
    pub duration_ms: i64,
    pub size_bytes: i64,
    pub sha256: String,
    pub mime_type: String,
    pub has_artwork: bool,
    pub revision: i64,
    pub created_at: i64,
}
pub(crate) async fn track(
    conn: &mut SqliteConnection,
    user: &str,
    id: &str,
) -> Result<Track, ApiError> {
    sqlx::query_as(&format!(
        "SELECT {TRACK_COLUMNS} FROM tracks WHERE user_id=? AND id=? AND deleted=0"
    ))
    .bind(user)
    .bind(id)
    .fetch_optional(conn)
    .await?
    .ok_or_else(ApiError::not_found)
}
#[derive(Deserialize)]
pub(crate) struct Cursor {
    cursor: Option<i64>,
}
#[derive(Serialize)]
pub(crate) struct Library {
    cursor: i64,
    reset: bool,
    tracks: Vec<Track>,
    deleted_track_ids: Vec<String>,
    playlists: Vec<crate::playlists::Playlist>,
    deleted_playlist_ids: Vec<String>,
}
pub(crate) async fn snapshot(
    State(state): State<AppState>,
    auth: Auth,
    Query(query): Query<Cursor>,
) -> Result<Json<Library>, ApiError> {
    if query.cursor.is_some_and(|v| v < 0) {
        return Err(ApiError::bad("cursor must be nonnegative"));
    }
    let mut tx = state.0.pool.begin().await?;
    let revision: i64 = sqlx::query_scalar("SELECT revision FROM users WHERE id=?")
        .bind(&auth.user)
        .fetch_one(&mut *tx)
        .await?;
    let reset = query.cursor.is_none_or(|v| v > revision);
    let cursor = if reset {
        -1
    } else {
        query.cursor.unwrap_or(-1)
    };
    let tracks = sqlx::query_as(&format!("SELECT {TRACK_COLUMNS} FROM tracks WHERE user_id=? AND revision>? AND deleted=0 ORDER BY revision,id"))
        .bind(&auth.user).bind(cursor).fetch_all(&mut *tx).await?;
    let deleted_track_ids = if reset {
        vec![]
    } else {
        sqlx::query_scalar("SELECT id FROM tracks WHERE user_id=? AND revision>? AND deleted=1 ORDER BY revision,id").bind(&auth.user).bind(cursor).fetch_all(&mut *tx).await?
    };
    let ids: Vec<String> = sqlx::query_scalar("SELECT id FROM playlists WHERE user_id=? AND revision>? AND deleted=0 ORDER BY revision,id").bind(&auth.user).bind(cursor).fetch_all(&mut *tx).await?;
    let mut playlists = Vec::with_capacity(ids.len());
    for id in ids {
        playlists.push(crate::playlists::load(&mut tx, &auth.user, &id).await?);
    }
    let deleted_playlist_ids = if reset {
        vec![]
    } else {
        sqlx::query_scalar("SELECT id FROM playlists WHERE user_id=? AND revision>? AND deleted=1 ORDER BY revision,id").bind(&auth.user).bind(cursor).fetch_all(&mut *tx).await?
    };
    tx.commit().await?;
    Ok(Json(Library {
        cursor: revision,
        reset,
        tracks,
        deleted_track_ids,
        playlists,
        deleted_playlist_ids,
    }))
}
#[derive(Default)]
pub(crate) enum NumberPatch {
    #[default]
    Missing,
    Value(Option<i64>),
}
impl<'de> Deserialize<'de> for NumberPatch {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Option::<i64>::deserialize(deserializer).map(Self::Value)
    }
}
impl NumberPatch {
    fn apply(self, old: Option<i64>) -> Result<Option<i64>, ApiError> {
        let value = match self {
            Self::Missing => old,
            Self::Value(value) => value,
        };
        if value.is_some_and(|v| !(1..=1_000_000).contains(&v)) {
            return Err(ApiError::bad("track/disc number out of range"));
        }
        Ok(value)
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TrackPatch {
    revision: i64,
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    #[serde(default)]
    track_number: NumberPatch,
    #[serde(default)]
    disc_number: NumberPatch,
}
pub(crate) async fn update_track(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    Json(input): Json<TrackPatch>,
) -> Result<Json<Track>, ApiError> {
    for value in [
        &input.title,
        &input.artist,
        &input.album,
        &input.album_artist,
    ]
    .into_iter()
    .flatten()
    {
        text(value, 4096)?;
    }
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let old = track(&mut tx, &auth.user, &id).await?;
    if input.revision != old.revision {
        return Err(ApiError::conflict("stale track revision"));
    }
    let track_number = input.track_number.apply(old.track_number)?;
    let disc_number = input.disc_number.apply(old.disc_number)?;
    let revision = bump(&mut tx, &auth.user).await?;
    sqlx::query("UPDATE tracks SET title=?,artist=?,album=?,album_artist=?,track_number=?,disc_number=?,revision=? WHERE user_id=? AND id=? AND deleted=0")
        .bind(input.title.unwrap_or(old.title)).bind(input.artist.unwrap_or(old.artist)).bind(input.album.unwrap_or(old.album)).bind(input.album_artist.unwrap_or(old.album_artist))
        .bind(track_number).bind(disc_number).bind(revision).bind(&auth.user).bind(&id).execute(&mut *tx).await?;
    let result = track(&mut tx, &auth.user, &id).await?;
    tx.commit().await?;
    Ok(Json(result))
}
pub(crate) async fn delete_track(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    track(&mut tx, &auth.user, &id).await?;
    let (audio_path, artwork_path): (String, Option<String>) =
        sqlx::query_as("SELECT audio_path,artwork_path FROM tracks WHERE user_id=? AND id=?")
            .bind(&auth.user)
            .bind(&id)
            .fetch_one(&mut *tx)
            .await?;
    let revision = bump(&mut tx, &auth.user).await?;
    let playlists: Vec<String> = sqlx::query_scalar("SELECT DISTINCT p.id FROM playlists p JOIN playlist_entries e ON e.playlist_id=p.id WHERE p.user_id=? AND p.deleted=0 AND e.track_id=?")
        .bind(&auth.user).bind(&id).fetch_all(&mut *tx).await?;
    for playlist in playlists {
        sqlx::query("DELETE FROM playlist_entries WHERE playlist_id=? AND track_id=?")
            .bind(&playlist)
            .bind(&id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE playlists SET revision=?,updated_at=? WHERE user_id=? AND id=?")
            .bind(revision)
            .bind(crate::now())
            .bind(&auth.user)
            .bind(playlist)
            .execute(&mut *tx)
            .await?;
    }
    // Keep tombstone metadata forever for delayed offline events and historical stats.
    sqlx::query("UPDATE tracks SET deleted=1,revision=? WHERE user_id=? AND id=?")
        .bind(revision)
        .bind(&auth.user)
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    // Unlink after commit. Existing Unix stream handles remain valid. GC retries
    // any failed deletion (including failures following cancellation or a crash).
    for path in std::iter::once(audio_path).chain(artwork_path) {
        let _ = tokio::fs::remove_file(state.0.config.data_dir.join("media").join(path)).await;
    }
    Ok(StatusCode::NO_CONTENT)
}
