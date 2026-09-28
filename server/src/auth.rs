use crate::{ApiError, AppState, id, now, text, valid_id};
use argon2::{
    Argon2, PasswordHash, PasswordHasher, PasswordVerifier,
    password_hash::{SaltString, rand_core::OsRng},
};
use axum::{
    Json,
    extract::{FromRequestParts, State},
    http::{StatusCode, request::Parts},
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::Row;

pub(crate) struct Auth {
    pub user: String,
    pub session: String,
}
impl FromRequestParts<AppState> for Auth {
    type Rejection = ApiError;
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .ok_or_else(ApiError::unauthorized)?;
        if token.len() != 64 {
            return Err(ApiError::unauthorized());
        }
        let row = sqlx::query("SELECT id,user_id FROM sessions WHERE access_hash=? AND revoked=0 AND access_expires>? AND refresh_expires>?")
            .bind(hash(token)).bind(now()).bind(now()).fetch_optional(&state.0.pool).await?.ok_or_else(ApiError::unauthorized)?;
        Ok(Self {
            user: row.get("user_id"),
            session: row.get("id"),
        })
    }
}
fn hash(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}
fn token() -> String {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}
fn password_hash(password: &str) -> anyhow::Result<String> {
    Argon2::default()
        .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
        .map(|p| p.to_string())
        .map_err(|e| anyhow::anyhow!("password hashing failed: {e}"))
}
pub async fn create_user(
    state: &AppState,
    username: &str,
    password: &str,
) -> anyhow::Result<String> {
    anyhow::ensure!(
        !username.trim().is_empty() && username.len() <= 128 && !username.contains('\0'),
        "username must be 1–128 bytes"
    );
    anyhow::ensure!(
        (12..=1024).contains(&password.len()),
        "password must be 12–1024 bytes"
    );
    let password = password.to_owned();
    let hashed = tokio::task::spawn_blocking(move || password_hash(&password)).await??;
    let user = id();
    sqlx::query("INSERT INTO users(id,username,password_hash) VALUES(?,?,?)")
        .bind(&user)
        .bind(username)
        .bind(hashed)
        .execute(&state.0.pool)
        .await?;
    Ok(user)
}
pub async fn reset_password(
    state: &AppState,
    username: &str,
    password: &str,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        (12..=1024).contains(&password.len()),
        "password must be 12–1024 bytes"
    );
    let password = password.to_owned();
    let hashed = tokio::task::spawn_blocking(move || password_hash(&password)).await??;
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let user: String =
        sqlx::query_scalar("UPDATE users SET password_hash=? WHERE username=? RETURNING id")
            .bind(hashed)
            .bind(username)
            .fetch_one(&mut *tx)
            .await?;
    sqlx::query("UPDATE sessions SET revoked=1 WHERE user_id=?")
        .bind(user)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}
#[derive(Deserialize)]
pub(crate) struct Login {
    username: String,
    password: String,
    device_id: String,
}
#[derive(Deserialize)]
pub(crate) struct Refresh {
    refresh_token: String,
}
#[derive(Serialize)]
pub(crate) struct Tokens {
    access_token: String,
    refresh_token: String,
    user: User,
    expires_at: i64,
}
#[derive(Serialize)]
struct User {
    id: String,
    username: String,
}

// Per-name + global admission control also bounds Argon2 work on nonexistent users.
// No forwarded-IP trust: deploy an IP limiter at the HTTPS reverse proxy too.
async fn rate_limit(state: &AppState, key: String, maximum: u32) -> Result<(), ApiError> {
    let now = now();
    let mut limits = state.0.login_limits.lock().await;
    limits.retain(|_, (until, _)| *until > now);
    if limits.len() >= 10000 && !limits.contains_key(&key) {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "authentication rate limit",
        ));
    }
    let entry = limits.entry(key).or_insert((now + 60_000, 0));
    if entry.1 >= maximum {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "authentication rate limit",
        ));
    }
    entry.1 += 1;
    Ok(())
}
pub(crate) async fn login(
    State(state): State<AppState>,
    Json(input): Json<Login>,
) -> Result<Json<Tokens>, ApiError> {
    text(&input.username, 128)?;
    if input.password.len() > 1024 {
        return Err(ApiError::bad("password too long"));
    }
    valid_id(&input.device_id)?;
    rate_limit(&state, "login:global".into(), 120).await?;
    rate_limit(
        &state,
        format!("login:{}", input.username.to_lowercase()),
        10,
    )
    .await?;
    let permit = state
        .0
        .passwords
        .clone()
        .try_acquire_owned()
        .map_err(|_| ApiError::new(StatusCode::TOO_MANY_REQUESTS, "authentication busy"))?;
    let row = sqlx::query("SELECT id,username,password_hash FROM users WHERE username=?")
        .bind(&input.username)
        .fetch_optional(&state.0.pool)
        .await?;
    let saved_hash: Option<String> = row.as_ref().map(|r| r.get("password_hash"));
    let expected = saved_hash.clone();
    let valid = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        // Same expensive Argon2 operation for unknown names to reduce enumeration.
        if let Some(hash) = expected {
            PasswordHash::new(&hash).is_ok_and(|hash| {
                Argon2::default()
                    .verify_password(input.password.as_bytes(), &hash)
                    .is_ok()
            })
        } else {
            let _ = password_hash(&input.password);
            false
        }
    })
    .await
    .map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "password verification failed",
        )
    })?;
    if !valid {
        return Err(ApiError::unauthorized());
    }
    let row = row.ok_or_else(ApiError::unauthorized)?;
    let user: String = row.get("id");
    let username: String = row.get("username");
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    // A concurrent password reset must not allow a session using the old password.
    let current: String = sqlx::query_scalar("SELECT password_hash FROM users WHERE id=?")
        .bind(&user)
        .fetch_one(&mut *tx)
        .await?;
    if Some(current) != saved_hash {
        return Err(ApiError::unauthorized());
    }
    sqlx::query("INSERT OR IGNORE INTO devices(user_id,id) VALUES(?,?)")
        .bind(&user)
        .bind(&input.device_id)
        .execute(&mut *tx)
        .await?;
    let result = Tokens {
        access_token: token(),
        refresh_token: token(),
        user: User {
            id: user.clone(),
            username,
        },
        expires_at: now() + state.0.config.access_ttl_ms,
    };
    sqlx::query("INSERT INTO sessions(id,user_id,device_id,access_hash,refresh_hash,access_expires,refresh_expires) VALUES(?,?,?,?,?,?,?)")
        .bind(id()).bind(user).bind(input.device_id).bind(hash(&result.access_token)).bind(hash(&result.refresh_token))
        .bind(result.expires_at).bind(now()+state.0.config.refresh_ttl_ms).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(result))
}
pub(crate) async fn refresh(
    State(state): State<AppState>,
    Json(input): Json<Refresh>,
) -> Result<Json<Tokens>, ApiError> {
    rate_limit(&state, "refresh:global".into(), 600).await?;
    if input.refresh_token.len() != 64 {
        return Err(ApiError::unauthorized());
    }
    let _guard = state.0.writes.lock().await;
    let mut tx = state.0.pool.begin().await?;
    let row = sqlx::query("SELECT s.id,s.user_id,u.username FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.refresh_hash=? AND s.revoked=0 AND s.refresh_expires>?")
        .bind(hash(&input.refresh_token)).bind(now()).fetch_optional(&mut *tx).await?.ok_or_else(ApiError::unauthorized)?;
    let result = Tokens {
        access_token: token(),
        refresh_token: token(),
        user: User {
            id: row.get("user_id"),
            username: row.get("username"),
        },
        expires_at: now() + state.0.config.access_ttl_ms,
    };
    sqlx::query("UPDATE sessions SET access_hash=?,refresh_hash=?,access_expires=?,refresh_expires=? WHERE id=?")
        .bind(hash(&result.access_token)).bind(hash(&result.refresh_token)).bind(result.expires_at).bind(now()+state.0.config.refresh_ttl_ms)
        .bind(row.get::<String,_>("id")).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(result))
}
pub(crate) async fn logout(
    State(state): State<AppState>,
    auth: Auth,
    Json(input): Json<Refresh>,
) -> Result<StatusCode, ApiError> {
    let _guard = state.0.writes.lock().await;
    // Only the authenticated session can be revoked with this endpoint.
    let result =
        sqlx::query("UPDATE sessions SET revoked=1 WHERE id=? AND user_id=? AND refresh_hash=?")
            .bind(auth.session)
            .bind(auth.user)
            .bind(hash(&input.refresh_token))
            .execute(&state.0.pool)
            .await?;
    if result.rows_affected() == 0 {
        return Err(ApiError::unauthorized());
    }
    Ok(StatusCode::NO_CONTENT)
}
