use crate::{ApiError, AppState, auth::Auth, bump, id, now, text, valid_id};
use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, Row, SqliteConnection};
use std::collections::HashSet;

#[derive(Deserialize, Serialize, FromRow, Debug)]
#[serde(deny_unknown_fields)]
pub(crate) struct Entry {
    id: String,
    track_id: String,
}
#[derive(Serialize, Debug)]
pub(crate) struct Playlist {
    id: String,
    name: String,
    revision: i64,
    entries: Vec<Entry>,
    updated_at: i64,
}
pub(crate) async fn load(
    conn: &mut SqliteConnection,
    user: &str,
    id: &str,
) -> Result<Playlist, ApiError> {
    let row = sqlx::query(
        "SELECT id,name,revision,updated_at FROM playlists WHERE user_id=? AND id=? AND deleted=0",
    )
    .bind(user)
    .bind(id)
    .fetch_optional(&mut *conn)
    .await?
    .ok_or_else(ApiError::not_found)?;
    let entries = sqlx::query_as("SELECT e.id,e.track_id FROM playlist_entries e JOIN playlists p ON p.id=e.playlist_id WHERE p.user_id=? AND p.id=? ORDER BY e.position")
        .bind(user).bind(id).fetch_all(conn).await?;
    Ok(Playlist {
        id: row.get("id"),
        name: row.get("name"),
        revision: row.get("revision"),
        updated_at: row.get("updated_at"),
        entries,
    })
}
fn name(value: &str) -> Result<(), ApiError> {
    text(value, 512)?;
    if value.trim().is_empty() {
        return Err(ApiError::bad("name must not be empty"));
    }
    Ok(())
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct New {
    name: String,
}
pub(crate) async fn create(
    State(state): State<AppState>,
    auth: Auth,
    Json(input): Json<New>,
) -> Result<Json<Playlist>, ApiError> {
    name(&input.name)?;
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM playlists WHERE user_id=? AND deleted=0")
            .bind(&auth.user)
            .fetch_one(&mut *tx)
            .await?;
    if count >= 10000 {
        return Err(ApiError::bad("playlist limit reached"));
    }
    let id = id();
    let revision = bump(&mut tx, &auth.user).await?;
    sqlx::query("INSERT INTO playlists(id,user_id,name,revision,updated_at) VALUES(?,?,?,?,?)")
        .bind(&id)
        .bind(&auth.user)
        .bind(input.name)
        .bind(revision)
        .bind(now())
        .execute(&mut *tx)
        .await?;
    let result = load(&mut tx, &auth.user, &id).await?;
    tx.commit().await?;
    Ok(Json(result))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Replace {
    revision: i64,
    name: String,
    entries: Vec<Entry>,
}
pub(crate) async fn replace(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    Json(input): Json<Replace>,
) -> Result<Json<Playlist>, ApiError> {
    name(&input.name)?;
    if input.entries.len() > 10000 {
        return Err(ApiError::bad("maximum 10000 playlist entries"));
    }
    let mut seen = HashSet::new();
    for entry in &input.entries {
        valid_id(&entry.id)?;
        valid_id(&entry.track_id)?;
        if !seen.insert(&entry.id) {
            return Err(ApiError::bad("duplicate entry ID"));
        }
    }
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let old = load(&mut tx, &auth.user, &id).await?;
    if old.revision != input.revision {
        return Err(ApiError::conflict("stale playlist revision"));
    }
    let owned: HashSet<String> =
        sqlx::query_scalar("SELECT id FROM tracks WHERE user_id=? AND deleted=0")
            .bind(&auth.user)
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .collect();
    if input.entries.iter().any(|e| !owned.contains(&e.track_id)) {
        return Err(ApiError::bad("unknown track"));
    }
    let revision = bump(&mut tx, &auth.user).await?;
    sqlx::query("UPDATE playlists SET name=?,revision=?,updated_at=? WHERE user_id=? AND id=?")
        .bind(input.name)
        .bind(revision)
        .bind(now())
        .bind(&auth.user)
        .bind(&id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM playlist_entries WHERE playlist_id=? AND EXISTS(SELECT 1 FROM playlists WHERE id=? AND user_id=?)").bind(&id).bind(&id).bind(&auth.user).execute(&mut *tx).await?;
    for (position, entry) in input.entries.into_iter().enumerate() {
        sqlx::query(
            "INSERT INTO playlist_entries(playlist_id,id,track_id,position) VALUES(?,?,?,?)",
        )
        .bind(&id)
        .bind(entry.id)
        .bind(entry.track_id)
        .bind(position as i64)
        .execute(&mut *tx)
        .await?;
    }
    let result = load(&mut tx, &auth.user, &id).await?;
    tx.commit().await?;
    Ok(Json(result))
}
#[derive(Deserialize)]
pub(crate) struct Revision {
    revision: i64,
}
pub(crate) async fn remove(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    Query(input): Query<Revision>,
) -> Result<StatusCode, ApiError> {
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let old = load(&mut tx, &auth.user, &id).await?;
    if old.revision != input.revision {
        return Err(ApiError::conflict("stale playlist revision"));
    }
    let revision = bump(&mut tx, &auth.user).await?;
    sqlx::query("UPDATE playlists SET deleted=1,revision=?,updated_at=? WHERE user_id=? AND id=?")
        .bind(revision)
        .bind(now())
        .bind(&auth.user)
        .bind(&id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM playlist_entries WHERE playlist_id=? AND EXISTS(SELECT 1 FROM playlists WHERE id=? AND user_id=?)").bind(&id).bind(&id).bind(&auth.user).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
