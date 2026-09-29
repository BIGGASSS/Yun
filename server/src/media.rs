use crate::{
    ApiError, AppState, MAX_ARTWORK,
    auth::Auth,
    bump,
    library::{self, Track},
};
use axum::{
    Extension, Json,
    body::{Body, Bytes},
    extract::{Path, State},
    http::{HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
};
use lofty::{
    config::{GlobalOptions, ParseOptions, ParsingMode, apply_global_options},
    file::{AudioFile, FileType, TaggedFileExt},
    prelude::{Accessor, ItemKey},
    probe::Probe,
};
use sha2::{Digest, Sha256};
use sqlx::Row;
use std::{
    io::{BufReader, Read, Seek, SeekFrom},
    path::Path as FsPath,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio_util::io::ReaderStream;

pub(crate) struct Metadata {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub track_number: Option<i64>,
    pub disc_number: Option<i64>,
    pub duration_ms: i64,
    pub sha256: String,
    pub mime_type: &'static str,
    pub artwork: Option<(Vec<u8>, &'static str)>,
}
struct LimitedReader {
    file: std::fs::File,
    remaining: u64,
    length: u64,
    failed: Arc<AtomicBool>,
    deadline: Instant,
}
impl Read for LimitedReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.remaining == 0 || Instant::now() > self.deadline {
            self.failed.store(true, Ordering::Relaxed);
            return Err(std::io::Error::other("parser budget exceeded"));
        }
        let limit = buf.len().min(self.remaining as usize);
        let n = self.file.read(&mut buf[..limit])?;
        self.remaining -= n as u64;
        Ok(n)
    }
}
impl Seek for LimitedReader {
    fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
        if Instant::now() > self.deadline {
            self.failed.store(true, Ordering::Relaxed);
            return Err(std::io::Error::other("parser budget exceeded"));
        }
        let position = self.file.seek(position)?;
        if position > self.length {
            self.failed.store(true, Ordering::Relaxed);
            return Err(std::io::Error::other("audio structure extends beyond file"));
        }
        Ok(position)
    }
}
pub(crate) fn parse(path: &FsPath, filename: &str) -> Result<Metadata, ApiError> {
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut file = std::fs::File::open(path)?;
    let length = file.metadata()?.len();
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        if Instant::now() > deadline {
            return Err(ApiError::bad("hash/parser budget exceeded"));
        }
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
    }
    file.seek(SeekFrom::Start(0))?;
    apply_global_options(
        GlobalOptions::new()
            .allocation_limit(16 * 1024 * 1024)
            .use_custom_resolvers(false)
            .preserve_format_specific_items(false),
    );
    let failed = Arc::new(AtomicBool::new(false));
    let reader = BufReader::new(LimitedReader {
        file,
        length,
        failed: failed.clone(),
        remaining: length
            .saturating_mul(3)
            .saturating_add(16 * 1024 * 1024)
            .min(128 * 1024 * 1024),
        deadline,
    });
    let parsed = Probe::new(reader)
        .guess_file_type()
        .map_err(|_| ApiError::bad("unrecognized audio"))?
        .options(
            ParseOptions::new()
                .parsing_mode(ParsingMode::Strict)
                .max_junk_bytes(1024),
        )
        .read()
        .map_err(|_| ApiError::bad("invalid, unsupported, or oversized audio metadata"))?;
    if failed.load(Ordering::Relaxed) || Instant::now() > deadline {
        return Err(ApiError::bad("truncated audio or parser budget exceeded"));
    }
    let mime_type = match parsed.file_type() {
        FileType::Mpeg => "audio/mpeg",
        FileType::Aac => "audio/aac",
        FileType::Mp4 => "audio/mp4",
        FileType::Flac => "audio/flac",
        FileType::Opus | FileType::Vorbis => "audio/ogg",
        FileType::Wav => "audio/wav",
        FileType::Aiff => "audio/aiff",
        _ => return Err(ApiError::bad("unsupported audio format")),
    };
    let properties = parsed.properties();
    let duration_ms = properties.duration().as_millis() as i64;
    if duration_ms <= 0
        || duration_ms > 7 * 24 * 3600 * 1000
        || properties.sample_rate().unwrap_or(0) == 0
        || properties.channels().unwrap_or(0) == 0
    {
        return Err(ApiError::bad(
            "invalid audio properties (duration must be at most 7 days)",
        ));
    }
    let tag = parsed.primary_tag().or_else(|| parsed.first_tag());
    let clean =
        |value: String| -> String { value.chars().filter(|c| *c != '\0').take(1024).collect() };
    let fallback = FsPath::new(filename)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Untitled")
        .to_owned();
    let title = clean(
        tag.and_then(|t| t.title())
            .map(|s| s.into_owned())
            .filter(|s| !s.is_empty())
            .unwrap_or(fallback),
    );
    let artist = clean(
        tag.and_then(|t| t.artist())
            .map(|s| s.into_owned())
            .unwrap_or_default(),
    );
    let album = clean(
        tag.and_then(|t| t.album())
            .map(|s| s.into_owned())
            .unwrap_or_default(),
    );
    let album_artist = clean(
        tag.and_then(|t| t.get_string(&ItemKey::AlbumArtist))
            .unwrap_or("")
            .to_owned(),
    );
    let number = |v: Option<u32>| v.filter(|v| (1..=1_000_000).contains(v)).map(i64::from);
    let artwork = parsed
        .tags()
        .iter()
        .flat_map(|t| t.pictures())
        .take(8)
        .find_map(|picture| {
            let data = picture.data();
            validate_image(data).ok().map(|mime| (data.to_vec(), mime))
        });
    Ok(Metadata {
        title,
        artist,
        album,
        album_artist,
        track_number: number(tag.and_then(|t| t.track())),
        disc_number: number(tag.and_then(|t| t.disk())),
        duration_ms,
        sha256: hex::encode(digest.finalize()),
        mime_type,
        artwork,
    })
}
pub(crate) fn validate_image(data: &[u8]) -> Result<&'static str, ApiError> {
    if data.is_empty() || data.len() > MAX_ARTWORK {
        return Err(ApiError::bad("image must be at most 10 MiB"));
    }
    let format = image::guess_format(data).map_err(|_| ApiError::bad("invalid image"))?;
    let mime = match format {
        image::ImageFormat::Jpeg => "image/jpeg",
        image::ImageFormat::Png => "image/png",
        _ => return Err(ApiError::bad("only JPEG and PNG artwork is supported")),
    };
    let mut reader = image::ImageReader::with_format(std::io::Cursor::new(data), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    reader
        .decode()
        .map_err(|_| ApiError::bad("invalid image or image exceeds decode limits"))?;
    Ok(mime)
}
pub(crate) async fn sync_dir(path: &FsPath) -> Result<(), ApiError> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || std::fs::File::open(path)?.sync_all())
        .await
        .map_err(|_| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "directory sync failed"))??;
    Ok(())
}
pub(crate) struct StagedArt {
    name: String,
    path: std::path::PathBuf,
    guard: Option<tokio::sync::OwnedMutexGuard<()>>,
}
impl StagedArt {
    // Call with global publication lock held. Only a rename and directory sync,
    // never image decoding or multi-megabyte writes, happen in this phase.
    pub(crate) async fn publish(&self, state: &AppState) -> Result<String, ApiError> {
        tokio::fs::rename(
            &self.path,
            state.0.config.data_dir.join("media").join(&self.name),
        )
        .await?;
        sync_dir(&state.0.config.data_dir.join("media")).await?;
        Ok(self.name.clone())
    }
}
impl Drop for StagedArt {
    fn drop(&mut self) {
        let path = self.path.clone();
        let guard = self.guard.take();
        tokio::spawn(async move {
            let _guard = guard;
            let _ = tokio::fs::remove_file(path).await;
        });
    }
}
pub(crate) async fn stage_art(state: &AppState, bytes: &[u8]) -> Result<StagedArt, ApiError> {
    let name = format!("{}.art", crate::id());
    let guard = state.upload_lock(&name).await.lock_owned().await;
    let staged = StagedArt {
        path: state.0.config.data_dir.join("uploads").join(&name),
        name,
        guard: Some(guard),
    };
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&staged.path)
        .await?;
    file.write_all(bytes).await?;
    file.sync_all().await?;
    Ok(staged)
}
pub(crate) async fn put_artwork(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    headers: HeaderMap,
    Extension(admission): Extension<crate::admission::Admission>,
    bytes: Bytes,
) -> Result<Json<Track>, ApiError> {
    // Keep reservations and file/commit exclusion until work actually finishes,
    // even if the HTTP request times out or disconnects.
    tokio::spawn(async move {
    let _admission = admission.0;
    let revision = headers
        .get("if-match")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix('"'))
        .and_then(|v| v.strip_suffix('"'))
        .and_then(|v| v.parse::<i64>().ok())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::PRECONDITION_REQUIRED,
                "If-Match with quoted track revision required",
            )
        })?;
    let permit = state
        .0
        .parsers
        .clone()
        .try_acquire_owned()
        .map_err(|_| ApiError::new(StatusCode::TOO_MANY_REQUESTS, "media parser busy"))?;
    let (bytes, mime) = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        validate_image(&bytes).map(|mime| (bytes, mime))
    })
    .await
    .map_err(|_| ApiError::bad("image parser failed"))??;
    let staged = stage_art(&state, &bytes).await?;
    let guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let old = library::track(&mut tx, &auth.user, &id).await?;
    if old.revision != revision {
        return Err(ApiError::conflict("stale track revision"));
    }
    let (old_path, old_size): (Option<String>, i64) = sqlx::query_as(
        "SELECT artwork_path,artwork_size_bytes FROM tracks WHERE user_id=? AND id=?",
    )
    .bind(&auth.user)
    .bind(&id)
    .fetch_one(&mut *tx)
    .await?;
    let used: i64=sqlx::query_scalar("SELECT (SELECT COALESCE(SUM(size_bytes+artwork_size_bytes),0) FROM tracks WHERE user_id=? AND deleted=0)+(SELECT COALESCE(SUM(size_bytes),0) FROM uploads WHERE user_id=? AND completed_track_id IS NULL)")
        .bind(&auth.user).bind(&auth.user).fetch_one(&mut *tx).await?;
    if bytes.len() as i64 > state.0.config.quota_bytes.saturating_sub(used - old_size) {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "artwork exceeds account quota",
        ));
    }
    let path = staged.publish(&state).await?;
    let revision = bump(&mut tx, &auth.user).await?;
    sqlx::query("UPDATE tracks SET artwork_path=?,artwork_mime=?,artwork_size_bytes=?,revision=? WHERE user_id=? AND id=? AND deleted=0")
        .bind(path).bind(mime).bind(bytes.len() as i64).bind(revision).bind(&auth.user).bind(&id).execute(&mut *tx).await?;
    let result = library::track(&mut tx, &auth.user, &id).await?;
    tx.commit().await?;
    drop(guard);
    if let Some(path) = old_path {
        let _ = tokio::fs::remove_file(state.0.config.data_dir.join("media").join(path)).await;
    }
    Ok(Json(result))
    }).await.map_err(|_| ApiError::bad("artwork worker failed"))?
}
pub(crate) async fn artwork(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let permit = crate::admission::stream_permit(&state)?;
    // Synchronize opening with GC; the file descriptor then survives unlink on Unix.
    let guard = state.0.writes.lock().await;
    let row = sqlx::query("SELECT artwork_path,artwork_mime FROM tracks WHERE user_id=? AND id=? AND deleted=0 AND artwork_path IS NOT NULL")
        .bind(auth.user).bind(id).fetch_optional(&state.0.pool).await?.ok_or_else(ApiError::not_found)?;
    let file = tokio::fs::File::open(
        state
            .0
            .config
            .data_dir
            .join("media")
            .join(row.get::<String, _>("artwork_path")),
    )
    .await?;
    let length = file.metadata().await?.len();
    drop(guard);
    let mut response =
        crate::admission::with_permit(Body::from_stream(ReaderStream::new(file)), permit)
            .into_response();
    let headers = response.headers_mut();
    headers.insert(
        "content-type",
        row.get::<String, _>("artwork_mime")
            .parse()
            .map_err(|_| ApiError::bad("invalid stored artwork MIME"))?,
    );
    headers.insert("content-length", length.into());
    headers.insert("cache-control", "private, no-cache".parse().unwrap());
    headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    Ok(response)
}
fn range(value: &str, length: u64) -> Option<(u64, u64)> {
    let value = value.strip_prefix("bytes=")?;
    if value.contains(',') || length == 0 {
        return None;
    }
    let (first, last) = value.split_once('-')?;
    let decimal = |s: &str| -> Option<u64> {
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
            None
        } else {
            s.parse().ok()
        }
    };
    if first.is_empty() {
        let suffix = decimal(last)?;
        if suffix == 0 {
            return None;
        }
        Some((length.saturating_sub(suffix), length - 1))
    } else {
        let start = decimal(first)?;
        let end = if last.is_empty() {
            length - 1
        } else {
            decimal(last)?.min(length - 1)
        };
        if start >= length || start > end {
            None
        } else {
            Some((start, end))
        }
    }
}
pub(crate) async fn audio(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    method: Method,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let permit = crate::admission::stream_permit(&state)?;
    let guard = state.0.writes.lock().await;
    let row = sqlx::query("SELECT audio_path,size_bytes,sha256,mime_type FROM tracks WHERE user_id=? AND id=? AND deleted=0")
        .bind(auth.user).bind(id).fetch_optional(&state.0.pool).await?.ok_or_else(ApiError::not_found)?;
    let mut file = tokio::fs::File::open(
        state
            .0
            .config
            .data_dir
            .join("media")
            .join(row.get::<String, _>("audio_path")),
    )
    .await?;
    drop(guard);
    let size = row.get::<i64, _>("size_bytes") as u64;
    let etag = format!("\"{}\"", row.get::<String, _>("sha256"));
    let requested = headers.get("range").filter(|_| {
        headers
            .get("if-range")
            .is_none_or(|v| v.as_bytes() == etag.as_bytes())
    });
    let (status, start, length) = if let Some(value) = requested {
        match value.to_str().ok().and_then(|v| range(v, size)) {
            Some((start, end)) => (StatusCode::PARTIAL_CONTENT, start, end - start + 1),
            None => {
                let mut response = ApiError::new(
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    "invalid or unsatisfiable byte range",
                )
                .into_response();
                response
                    .headers_mut()
                    .insert("content-range", format!("bytes */{size}").parse().unwrap());
                response
                    .headers_mut()
                    .insert("accept-ranges", "bytes".parse().unwrap());
                response.headers_mut().insert("etag", etag.parse().unwrap());
                return Ok(response);
            }
        }
    } else {
        (StatusCode::OK, 0, size)
    };
    file.seek(SeekFrom::Start(start)).await?;
    let body = if method == Method::HEAD {
        Body::empty()
    } else {
        crate::admission::with_permit(
            Body::from_stream(ReaderStream::new(file.take(length))),
            permit,
        )
    };
    let mut response = (status, body).into_response();
    let h = response.headers_mut();
    h.insert("content-length", length.into());
    h.insert("accept-ranges", "bytes".parse().unwrap());
    h.insert("etag", etag.parse().unwrap());
    h.insert(
        "content-type",
        row.get::<String, _>("mime_type")
            .parse()
            .map_err(|_| ApiError::bad("invalid stored MIME"))?,
    );
    h.insert("cache-control", "private, no-cache".parse().unwrap());
    h.insert("x-content-type-options", "nosniff".parse().unwrap());
    if status == StatusCode::PARTIAL_CONTENT {
        h.insert(
            "content-range",
            format!("bytes {start}-{}/{size}", start + length - 1)
                .parse()
                .unwrap(),
        );
    }
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::range;
    #[test]
    fn byte_ranges() {
        for (input, expected) in [
            ("bytes=0-9", Some((0, 9))),
            ("bytes=95-", Some((95, 99))),
            ("bytes=-10", Some((90, 99))),
            ("bytes=-1000", Some((0, 99))),
            ("bytes=0-999", Some((0, 99))),
            ("bytes=100-", None),
            ("bytes=8-7", None),
            ("bytes=-0", None),
            ("bytes=+1-4", None),
            ("bytes=1-2,4-5", None),
            ("items=1-2", None),
        ] {
            assert_eq!(range(input, 100), expected, "{input}");
        }
    }
}
