use crate::{
    ApiError, AppState,
    auth::Auth,
    bump, id,
    library::{self, Track},
    media, now, text,
};
use axum::{
    Json,
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, SqliteConnection};

#[derive(Serialize, FromRow)]
pub(crate) struct Upload {
    id: String,
    offset: i64,
    size_bytes: i64,
    filename: String,
}
async fn load(conn: &mut SqliteConnection, user: &str, id: &str) -> Result<Upload, ApiError> {
    sqlx::query_as("SELECT id,offset,size_bytes,filename FROM uploads WHERE user_id=? AND id=?")
        .bind(user)
        .bind(id)
        .fetch_optional(conn)
        .await?
        .ok_or_else(ApiError::not_found)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct New {
    filename: String,
    size_bytes: i64,
}
#[derive(Serialize)]
pub(crate) struct Offset {
    id: String,
    offset: i64,
}
pub(crate) async fn create(
    State(state): State<AppState>,
    auth: Auth,
    Json(input): Json<New>,
) -> Result<Json<Offset>, ApiError> {
    text(&input.filename, 512)?;
    if input.filename.trim().is_empty() || input.filename.contains(['/', '\\']) {
        return Err(ApiError::bad("filename must be a basename"));
    }
    if input.size_bytes <= 0 || input.size_bytes > state.0.config.max_file_bytes {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "file size outside configured limit",
        ));
    }
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let used: i64=sqlx::query_scalar("SELECT (SELECT COALESCE(SUM(size_bytes+artwork_size_bytes),0) FROM tracks WHERE user_id=? AND deleted=0)+(SELECT COALESCE(SUM(size_bytes),0) FROM uploads WHERE user_id=? AND completed_track_id IS NULL)").bind(&auth.user).bind(&auth.user).fetch_one(&mut *tx).await?;
    if input.size_bytes > state.0.config.quota_bytes.saturating_sub(used) {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "account storage quota exceeded",
        ));
    }
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM uploads WHERE user_id=? AND completed_track_id IS NULL",
    )
    .bind(&auth.user)
    .fetch_one(&mut *tx)
    .await?;
    if count >= 100 {
        return Err(ApiError::bad("maximum 100 pending uploads per account"));
    }
    let count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM tracks WHERE user_id=? AND deleted=0")
            .bind(&auth.user)
            .fetch_one(&mut *tx)
            .await?;
    if count >= 50000 {
        return Err(ApiError::bad("maximum 50000 live tracks per account"));
    }
    let id = id();
    let file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(state.0.config.data_dir.join("uploads").join(&id))
        .await?;
    file.sync_all().await?;
    media::sync_dir(&state.0.config.data_dir.join("uploads")).await?;
    sqlx::query("INSERT INTO uploads(id,user_id,filename,size_bytes,updated_at) VALUES(?,?,?,?,?)")
        .bind(&id)
        .bind(auth.user)
        .bind(input.filename)
        .bind(input.size_bytes)
        .bind(now())
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(Offset { id, offset: 0 }))
}
pub(crate) async fn status(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<Json<Upload>, ApiError> {
    let mut connection = state.0.pool.acquire().await?;
    Ok(Json(load(&mut connection, &auth.user, &id).await?))
}
pub(crate) async fn append(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<Offset>, ApiError> {
    let offset = headers
        .get("upload-offset")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<i64>().ok())
        .filter(|v| *v >= 0)
        .ok_or_else(|| ApiError::bad("valid Upload-Offset required"))?;
    if bytes.is_empty() {
        return Err(ApiError::bad("empty upload chunk"));
    }
    let guard = state.0.writes.clone().lock_owned().await;
    let mut tx = state.0.pool.begin().await?;
    let upload = load(&mut tx, &auth.user, &id).await?;
    if upload.offset != offset {
        return Err(ApiError::conflict(
            "upload offset mismatch; GET the upload to resume",
        ));
    }
    if bytes.len() as i64 > upload.size_bytes - offset {
        return Err(ApiError::bad("chunk exceeds declared file size"));
    }
    let path = state.0.config.data_dir.join("uploads").join(&upload.id);
    let length = bytes.len() as i64;
    // Keep the write lock inside the blocking IO job. Dropping a timed-out HTTP
    // future cannot let a retry race an in-flight filesystem write.
    let (_guard, result) = tokio::task::spawn_blocking(move || {
        use std::io::{Seek, Write};
        let result = (|| -> Result<(), ApiError> {
            let mut file = std::fs::OpenOptions::new().write(true).open(path)?;
            if file.metadata()?.len() < (offset as u64) {
                return Err(ApiError::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "upload storage is shorter than durable offset",
                ));
            }
            // Any tail beyond the committed offset is from an uncommitted request.
            file.set_len(offset as u64)?;
            file.seek(std::io::SeekFrom::Start(offset as u64))?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            Ok(())
        })();
        (guard, result)
    })
    .await
    .map_err(|_| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "upload writer failed"))?;
    result?;
    let offset = offset + length;
    sqlx::query("UPDATE uploads SET offset=?,updated_at=? WHERE user_id=? AND id=?")
        .bind(offset)
        .bind(now())
        .bind(auth.user)
        .bind(&id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(Offset { id, offset }))
}
pub(crate) async fn cancel(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let _guard = state.0.writes.lock().await;
    let result = sqlx::query("DELETE FROM uploads WHERE user_id=? AND id=?")
        .bind(auth.user)
        .bind(&id)
        .execute(&state.0.pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    // Delete database reservation first. Failed unlinks are safe and retried by GC.
    let _ = tokio::fs::remove_file(state.0.config.data_dir.join("uploads").join(id)).await;
    Ok(StatusCode::NO_CONTENT)
}
pub(crate) async fn complete(
    State(state): State<AppState>,
    auth: Auth,
    Path(upload_id): Path<String>,
) -> Result<Json<Track>, ApiError> {
    let permit = state
        .0
        .parsers
        .clone()
        .try_acquire_owned()
        .map_err(|_| ApiError::new(StatusCode::TOO_MANY_REQUESTS, "media parser busy"))?;
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let upload = load(&mut tx, &auth.user, &upload_id).await?;
    let completed: Option<String> =
        sqlx::query_scalar("SELECT completed_track_id FROM uploads WHERE user_id=? AND id=?")
            .bind(&auth.user)
            .bind(&upload_id)
            .fetch_one(&mut *tx)
            .await?;
    if let Some(track_id) = completed {
        let result = library::track(&mut tx, &auth.user, &track_id).await?;
        tx.commit().await?;
        return Ok(Json(result));
    }
    if upload.offset != upload.size_bytes {
        return Err(ApiError::conflict("upload is incomplete"));
    }
    let source = state.0.config.data_dir.join("uploads").join(&upload.id);
    if tokio::fs::metadata(&source).await?.len() != upload.size_bytes as u64 {
        return Err(ApiError::bad("upload length mismatch"));
    }
    let path = source.clone();
    let metadata = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        media::parse(&path, &upload.filename)
    })
    .await
    .map_err(|_| ApiError::bad("audio parser failed"))??;
    let existing: Option<String> =
        sqlx::query_scalar("SELECT id FROM tracks WHERE user_id=? AND sha256=? AND deleted=0")
            .bind(&auth.user)
            .bind(&metadata.sha256)
            .fetch_optional(&mut *tx)
            .await?;
    let track_id = if let Some(existing) = existing {
        existing
    } else {
        let artwork_size = metadata
            .artwork
            .as_ref()
            .map_or(0, |(data, _)| data.len() as i64);
        let used: i64=sqlx::query_scalar("SELECT (SELECT COALESCE(SUM(size_bytes+artwork_size_bytes),0) FROM tracks WHERE user_id=? AND deleted=0)+(SELECT COALESCE(SUM(size_bytes),0) FROM uploads WHERE user_id=? AND completed_track_id IS NULL)")
            .bind(&auth.user).bind(&auth.user).fetch_one(&mut *tx).await?;
        if artwork_size > state.0.config.quota_bytes.saturating_sub(used) {
            return Err(ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "artwork exceeds account quota",
            ));
        }
        let track_id = id();
        let audio_path = format!("{track_id}.audio");
        // Hard-link instead of move: the upload remains recoverable until DB commit.
        tokio::fs::hard_link(
            &source,
            state.0.config.data_dir.join("media").join(&audio_path),
        )
        .await?;
        media::sync_dir(&state.0.config.data_dir.join("media")).await?;
        let (artwork_path, artwork_mime) = if let Some((data, mime)) = metadata.artwork {
            (Some(media::store_art(&state, &data).await?), Some(mime))
        } else {
            (None, None)
        };
        let revision = bump(&mut tx, &auth.user).await?;
        sqlx::query("INSERT INTO tracks(id,user_id,title,artist,album,album_artist,track_number,disc_number,duration_ms,size_bytes,sha256,mime_type,artwork_path,artwork_mime,artwork_size_bytes,audio_path,revision,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            .bind(&track_id).bind(&auth.user).bind(metadata.title).bind(metadata.artist).bind(metadata.album).bind(metadata.album_artist).bind(metadata.track_number).bind(metadata.disc_number)
            .bind(metadata.duration_ms).bind(upload.size_bytes).bind(metadata.sha256).bind(metadata.mime_type).bind(artwork_path).bind(artwork_mime).bind(artwork_size).bind(audio_path).bind(revision).bind(now()).execute(&mut *tx).await?;
        track_id
    };
    sqlx::query("UPDATE uploads SET completed_track_id=?,updated_at=? WHERE user_id=? AND id=?")
        .bind(&track_id)
        .bind(now())
        .bind(&auth.user)
        .bind(upload_id)
        .execute(&mut *tx)
        .await?;
    let result = library::track(&mut tx, &auth.user, &track_id).await?;
    tx.commit().await?;
    let _ = tokio::fs::remove_file(source).await;
    Ok(Json(result))
}

pub(crate) async fn cleanup(state: &AppState) -> anyhow::Result<()> {
    use std::collections::HashSet;
    let _guard = state.0.writes.lock().await;
    sqlx::query("DELETE FROM uploads WHERE updated_at<?")
        .bind(now() - state.0.config.upload_ttl_ms)
        .execute(&state.0.pool)
        .await?;
    let uploads: HashSet<String> =
        sqlx::query_scalar("SELECT id FROM uploads WHERE completed_track_id IS NULL")
            .fetch_all(&state.0.pool)
            .await?
            .into_iter()
            .collect();
    let media: HashSet<String>=sqlx::query_scalar("SELECT audio_path FROM tracks WHERE deleted=0 UNION SELECT artwork_path FROM tracks WHERE deleted=0 AND artwork_path IS NOT NULL").fetch_all(&state.0.pool).await?.into_iter().collect();
    for (directory, keep) in [("uploads", uploads), ("media", media)] {
        let mut files = tokio::fs::read_dir(state.0.config.data_dir.join(directory)).await?;
        while let Some(file) = files.next_entry().await? {
            if !keep.contains(&file.file_name().to_string_lossy().into_owned())
                && file.file_type().await?.is_file()
            {
                tokio::fs::remove_file(file.path()).await?;
            }
        }
    }
    sqlx::query("DELETE FROM sessions WHERE revoked=1 OR refresh_expires<?")
        .bind(now())
        .execute(&state.0.pool)
        .await?;
    Ok(())
}
