use crate::{ApiError, AppState, auth::Auth, bump, text};
use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, Row, SqliteConnection};
use std::collections::HashMap;

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
    page_token: Option<String>,
    #[serde(default)]
    paged: bool,
}
#[derive(Serialize)]
pub(crate) struct Library {
    cursor: i64,
    reset: bool,
    tracks: Vec<Track>,
    deleted_track_ids: Vec<String>,
    playlists: Vec<crate::playlists::Playlist>,
    deleted_playlist_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    next_page_token: Option<String>,
}
#[derive(Serialize, Deserialize)]
struct PageToken {
    user: String,
    revision: i64,
    cursor: i64,
    reset: bool,
    kind: u8,
    key_revision: i64,
    id: String,
    position: i64,
}
#[derive(FromRow)]
struct PlaylistRecord {
    id: String,
    name: String,
    revision: i64,
    updated_at: i64,
    position: i64,
    entry_id: Option<String>,
    track_id: Option<String>,
}
// Unary + prevents SQLite from choosing the original cursor's single-column
// bound instead of the advancing composite key. Both predicates are needed:
// the first page must exclude *all* rows at the original cursor revision.
fn sync_page_sql(table: &str, columns: &str, deleted: bool) -> String {
    format!(
        "SELECT {columns} FROM {table} WHERE user_id=? AND +revision>? AND deleted={} AND (revision,id)>(?,?) ORDER BY revision,id LIMIT ?",
        i32::from(deleted)
    )
}
const PLAYLIST_PAGE_SQL: &str = "SELECT p.id,p.name,p.revision,p.updated_at,COALESCE(e.position,-1) AS position,e.id AS entry_id,e.track_id FROM playlists p LEFT JOIN playlist_entries e ON e.playlist_id=p.id WHERE p.user_id=? AND +p.revision>? AND p.deleted=0 AND (p.revision,p.id)>(?,?) ORDER BY p.revision,p.id,e.position LIMIT ?";

pub(crate) async fn snapshot(
    State(state): State<AppState>,
    auth: Auth,
    Query(query): Query<Cursor>,
) -> Result<Json<Library>, ApiError> {
    if query.cursor.is_some_and(|v| v < 0) {
        return Err(ApiError::bad("cursor must be nonnegative"));
    }
    // A continuation is itself explicit pagination negotiation, including for
    // clients that omit `paged` on subsequent requests.
    let paged = query.paged || query.page_token.is_some();
    let mut tx = state.0.pool.begin().await?;
    let revision: i64 = sqlx::query_scalar("SELECT revision FROM users WHERE id=?")
        .bind(&auth.user)
        .fetch_one(&mut *tx)
        .await?;
    let mut page = if let Some(token) = query.page_token {
        if token.len() > 4096 {
            return Err(ApiError::bad("invalid page token"));
        }
        let bytes = hex::decode(token).map_err(|_| ApiError::bad("invalid page token"))?;
        let page: PageToken =
            serde_json::from_slice(&bytes).map_err(|_| ApiError::bad("invalid page token"))?;
        if page.user != auth.user
            || page.kind > 3
            || page.cursor < -1
            || page.cursor > page.revision
            || page.key_revision < page.cursor
            || page.key_revision > page.revision
            || page.position < -1
            || (page.reset && page.cursor != -1)
        {
            return Err(ApiError::bad("invalid page token"));
        }
        if page.revision != revision {
            return Err(ApiError::conflict("library changed; restart pagination"));
        }
        if !page.reset && query.cursor.is_some_and(|c| c != page.cursor) {
            return Err(ApiError::bad("cursor differs from page token"));
        }
        page
    } else {
        let reset = query.cursor.is_none_or(|v| v > revision);
        PageToken {
            user: auth.user.clone(),
            revision,
            cursor: if reset {
                -1
            } else {
                query.cursor.unwrap_or(-1)
            },
            reset,
            kind: 0,
            key_revision: if reset {
                -1
            } else {
                query.cursor.unwrap_or(-1)
            },
            id: String::new(),
            position: -1,
        }
    };
    let reset = page.reset;
    let mut tracks = Vec::new();
    let mut deleted_track_ids = Vec::new();
    let mut playlists: Vec<crate::playlists::Playlist> = Vec::new();
    let mut deleted_playlist_ids = Vec::new();
    // A joined entry record costs at most two response records (metadata +
    // entry). Thus 128 SQL records bound the response to <=256 total records,
    // including repeated metadata, even for a 10,000-entry playlist.
    let mut remaining = 128usize;
    while page.kind < 4 && remaining > 0 {
        if page.reset && (page.kind == 1 || page.kind == 3) {
            page.kind += 1;
            page.id.clear();
            page.position = -1;
            page.key_revision = page.cursor;
            continue;
        }
        let count;
        if page.kind == 0 {
            let rows: Vec<Track> = sqlx::query_as(&sync_page_sql("tracks", TRACK_COLUMNS, false))
                .bind(&auth.user)
                .bind(page.cursor)
                .bind(page.key_revision)
                .bind(&page.id)
                .bind(remaining as i64)
                .fetch_all(&mut *tx)
                .await?;
            count = rows.len();
            if let Some(last) = rows.last() {
                page.id.clone_from(&last.id);
                page.key_revision = last.revision;
            }
            tracks.extend(rows);
        } else if page.kind == 2 {
            // Resume the current playlist by its entry-position index, then
            // batch subsequent playlists. At most two queries per page, never
            // two per playlist and never rescanning preceding entry fragments.
            let mut rows: Vec<PlaylistRecord> = if page.position >= 0 {
                sqlx::query_as("SELECT p.id,p.name,p.revision,p.updated_at,e.position,e.id AS entry_id,e.track_id FROM playlists p JOIN playlist_entries e ON e.playlist_id=p.id WHERE p.user_id=? AND p.id=? AND p.revision=? AND p.deleted=0 AND e.position>? ORDER BY e.position LIMIT ?")
                    .bind(&auth.user).bind(&page.id).bind(page.key_revision).bind(page.position).bind(remaining as i64).fetch_all(&mut *tx).await?
            } else {
                Vec::new()
            };
            if rows.len() < remaining {
                let next: Vec<PlaylistRecord> = sqlx::query_as(PLAYLIST_PAGE_SQL)
                    .bind(&auth.user)
                    .bind(page.cursor)
                    .bind(page.key_revision)
                    .bind(&page.id)
                    .bind((remaining - rows.len()) as i64)
                    .fetch_all(&mut *tx)
                    .await?;
                rows.extend(next);
            }
            count = rows.len();
            let mut indices = HashMap::new();
            for row in rows {
                page.id.clone_from(&row.id);
                page.position = row.position;
                page.key_revision = row.revision;
                let index = *indices.entry(row.id.clone()).or_insert_with(|| {
                    let index = playlists.len();
                    playlists.push(crate::playlists::Playlist {
                        id: row.id,
                        name: row.name,
                        revision: row.revision,
                        updated_at: row.updated_at,
                        entries: Vec::new(),
                    });
                    index
                });
                if let (Some(id), Some(track_id)) = (row.entry_id, row.track_id) {
                    playlists[index]
                        .entries
                        .push(crate::playlists::Entry { id, track_id });
                }
            }
        } else {
            let table = if page.kind == 1 {
                "tracks"
            } else {
                "playlists"
            };
            let rows = sqlx::query(&sync_page_sql(table, "id,revision", true))
                .bind(&auth.user)
                .bind(page.cursor)
                .bind(page.key_revision)
                .bind(&page.id)
                .bind(remaining as i64)
                .fetch_all(&mut *tx)
                .await?;
            count = rows.len();
            for row in rows {
                let id: String = row.get("id");
                page.id.clone_from(&id);
                page.key_revision = row.get("revision");
                if page.kind == 1 {
                    deleted_track_ids.push(id);
                } else {
                    deleted_playlist_ids.push(id);
                }
            }
        }
        if count < remaining {
            page.kind += 1;
            page.id.clear();
            page.position = -1;
            page.key_revision = page.cursor;
        }
        remaining -= count;
    }
    let next_page_token = if page.kind < 4 {
        if !paged {
            return Err(ApiError::bad(
                "client upgrade required: library requires pagination; send paged=true and consume all next_page_token pages before saving cursor",
            ));
        }
        Some(hex::encode(
            serde_json::to_vec(&page).map_err(|_| ApiError::bad("page token encoding failed"))?,
        ))
    } else {
        None
    };
    tx.commit().await?;
    Ok(Json(Library {
        cursor: revision,
        reset,
        tracks,
        deleted_track_ids,
        playlists,
        deleted_playlist_ids,
        next_page_token,
    }))
}
#[cfg(test)]
mod pagination_tests {
    #[tokio::test]
    async fn continuation_seeks_composite_key_not_original_cursor() {
        let dir = tempfile::tempdir().unwrap();
        let state = crate::AppState::open(crate::Config::new(dir.path()))
            .await
            .unwrap();
        for query in [
            super::sync_page_sql("tracks", super::TRACK_COLUMNS, false),
            super::sync_page_sql("tracks", "id,revision", true),
            super::sync_page_sql("playlists", "id,revision", true),
            super::PLAYLIST_PAGE_SQL.to_owned(),
        ] {
            let rows = sqlx::query(&format!("EXPLAIN QUERY PLAN {query}"))
                .bind("u")
                .bind(0)
                .bind(1000)
                .bind("last-id")
                .bind(128)
                .fetch_all(&state.0.pool)
                .await
                .unwrap();
            use sqlx::Row;
            let plan: Vec<String> = rows.iter().map(|row| row.get("detail")).collect();
            assert!(
                plan.iter()
                    .any(|step| step.contains("sync_key") && step.contains("(revision,id)>(?,?)")),
                "{plan:?}"
            );
        }
    }
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
    sqlx::query("UPDATE playlists SET revision=?,updated_at=? WHERE user_id=? AND deleted=0 AND id IN (SELECT playlist_id FROM playlist_entries WHERE track_id=?)")
        .bind(revision).bind(crate::now()).bind(&auth.user).bind(&id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM playlist_entries WHERE track_id=? AND playlist_id IN (SELECT id FROM playlists WHERE user_id=? AND deleted=0)")
        .bind(&id).bind(&auth.user).execute(&mut *tx).await?;
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
