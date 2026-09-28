mod auth;
mod error;
mod events;
mod library;
mod media;
mod playlists;
mod uploads;

pub use auth::{create_user, reset_password};
use axum::{
    Router,
    extract::DefaultBodyLimit,
    routing::{get, patch, post, put},
};
pub use error::ApiError;
use sqlx::{
    SqlitePool,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
};
use std::{collections::HashMap, path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::{Mutex, Semaphore};
use tower_http::trace::TraceLayer;

pub const MAX_CHUNK: usize = 4 * 1024 * 1024;
pub const MAX_ARTWORK: usize = 10 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct Config {
    pub data_dir: PathBuf,
    pub max_file_bytes: i64,
    pub quota_bytes: i64,
    pub upload_ttl_ms: i64,
    pub access_ttl_ms: i64,
    pub refresh_ttl_ms: i64,
}
impl Config {
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        Self {
            data_dir: data_dir.into(),
            max_file_bytes: 1024 * 1024 * 1024,
            quota_bytes: 20 * 1024 * 1024 * 1024,
            upload_ttl_ms: 24 * 3600 * 1000,
            access_ttl_ms: 15 * 60 * 1000,
            refresh_ttl_ms: 30 * 24 * 3600 * 1000,
        }
    }
}

#[derive(Clone)]
pub struct AppState(pub(crate) Arc<Inner>);
pub(crate) struct Inner {
    pub pool: SqlitePool,
    pub _lock: std::fs::File,
    pub config: Config,
    // Serializes mutations involving database + filesystem. SQL transactions remain the
    // authority for atomicity; one server process per data directory is required.
    pub writes: Arc<Mutex<()>>,
    pub parsers: Arc<Semaphore>,
    pub passwords: Arc<Semaphore>,
    pub login_limits: Mutex<HashMap<String, (i64, u32)>>,
}
impl AppState {
    pub async fn open(config: Config) -> anyhow::Result<Self> {
        anyhow::ensure!(
            config.max_file_bytes > 0
                && config.quota_bytes > 0
                && config.upload_ttl_ms > 0
                && config.access_ttl_ms > 0
                && config.refresh_ttl_ms > 0,
            "limits must be positive"
        );
        tokio::fs::create_dir_all(config.data_dir.join("uploads")).await?;
        tokio::fs::create_dir_all(config.data_dir.join("media")).await?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(&config.data_dir, std::fs::Permissions::from_mode(0o700))
                .await?;
        }
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(config.data_dir.join("server.lock"))?;
        lock.try_lock().map_err(|e| anyhow::anyhow!("data directory already in use (stop the server before administrative commands): {e}"))?;
        let options = SqliteConnectOptions::new()
            .filename(config.data_dir.join("yun.sqlite3"))
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Full)
            .foreign_keys(true)
            .busy_timeout(Duration::from_secs(15));
        let pool = SqlitePoolOptions::new()
            .max_connections(8)
            .connect_with(options)
            .await?;
        sqlx::migrate!().run(&pool).await?;
        Ok(Self(Arc::new(Inner {
            pool,
            _lock: lock,
            config,
            writes: Arc::new(Mutex::new(())),
            parsers: Arc::new(Semaphore::new(2)),
            passwords: Arc::new(Semaphore::new(4)),
            login_limits: Mutex::new(HashMap::new()),
        })))
    }
    pub async fn cleanup(&self) -> anyhow::Result<()> {
        uploads::cleanup(self).await
    }
    pub async fn close(&self) {
        self.0.pool.close().await;
    }
    /// Offline consistent backup. Destination must not exist; stop the serving
    /// process before opening the same data directory with the CLI.
    pub async fn backup(&self, destination: &std::path::Path) -> anyhow::Result<()> {
        let _guard = self.0.writes.lock().await;
        tokio::fs::create_dir(destination).await?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(destination, std::fs::Permissions::from_mode(0o700)).await?;
        }
        let database = destination.join("yun.sqlite3");
        sqlx::query("VACUUM INTO ?")
            .bind(database.to_string_lossy().as_ref())
            .execute(&self.0.pool)
            .await?;
        for directory in ["uploads", "media"] {
            tokio::fs::create_dir(destination.join(directory)).await?;
            let mut entries = tokio::fs::read_dir(self.0.config.data_dir.join(directory)).await?;
            while let Some(entry) = entries.next_entry().await? {
                if entry.file_type().await?.is_file() {
                    let target = destination.join(directory).join(entry.file_name());
                    tokio::fs::copy(entry.path(), &target).await?;
                    tokio::fs::File::open(target).await?.sync_all().await?;
                }
            }
            media::sync_dir(&destination.join(directory))
                .await
                .map_err(|e| anyhow::anyhow!(e.message))?;
        }
        tokio::fs::File::open(database).await?.sync_all().await?;
        media::sync_dir(destination)
            .await
            .map_err(|e| anyhow::anyhow!(e.message))?;
        if let Some(parent) = destination.parent().filter(|p| !p.as_os_str().is_empty()) {
            media::sync_dir(parent)
                .await
                .map_err(|e| anyhow::anyhow!(e.message))?;
        }
        Ok(())
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route(
            "/health",
            get(|| async { axum::Json(serde_json::json!({"status":"ok"})) }),
        )
        .route("/api/v1/auth/login", post(auth::login))
        .route("/api/v1/auth/refresh", post(auth::refresh))
        .route("/api/v1/auth/logout", post(auth::logout))
        .route("/api/v1/library", get(library::snapshot))
        .route(
            "/api/v1/tracks/{id}",
            patch(library::update_track).delete(library::delete_track),
        )
        .route(
            "/api/v1/tracks/{id}/audio",
            get(media::audio).head(media::audio),
        )
        .route(
            "/api/v1/tracks/{id}/artwork",
            get(media::artwork)
                .put(media::put_artwork)
                .layer(DefaultBodyLimit::max(MAX_ARTWORK)),
        )
        .route("/api/v1/uploads", post(uploads::create))
        .route(
            "/api/v1/uploads/{id}",
            get(uploads::status)
                .patch(uploads::append)
                .delete(uploads::cancel)
                .layer(DefaultBodyLimit::max(MAX_CHUNK)),
        )
        .route("/api/v1/uploads/{id}/complete", post(uploads::complete))
        .route("/api/v1/playlists", post(playlists::create))
        .route(
            "/api/v1/playlists/{id}",
            put(playlists::replace).delete(playlists::remove),
        )
        .route("/api/v1/listening-events", post(events::ingest))
        .route("/api/v1/stats", get(events::stats))
        .fallback(|| async { ApiError::not_found() })
        .method_not_allowed_fallback(|| async {
            ApiError::new(
                axum::http::StatusCode::METHOD_NOT_ALLOWED,
                "method not allowed",
            )
        })
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .layer(tower::limit::ConcurrencyLimitLayer::new(128))
        .layer(tower_http::timeout::TimeoutLayer::with_status_code(
            axum::http::StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(60),
        ))
        .layer(axum::middleware::map_response(error::normalize))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

pub(crate) fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
pub(crate) fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub(crate) fn valid_id(value: &str) -> Result<(), ApiError> {
    match uuid::Uuid::parse_str(value) {
        Ok(id) if id.to_string() == value => Ok(()),
        _ => Err(ApiError::bad(
            "UUID must use canonical lowercase hyphenated form",
        )),
    }
}
pub(crate) fn text(value: &str, max: usize) -> Result<(), ApiError> {
    if value.len() > max || value.contains('\0') {
        return Err(ApiError::bad("text field too long or contains NUL"));
    }
    Ok(())
}
pub(crate) async fn bump(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user: &str,
) -> Result<i64, ApiError> {
    Ok(
        sqlx::query_scalar("UPDATE users SET revision=revision+1 WHERE id=? RETURNING revision")
            .bind(user)
            .fetch_one(&mut **tx)
            .await?,
    )
}
