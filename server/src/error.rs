use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub message: String,
}
impl ApiError {
    pub fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
    pub fn bad(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, message)
    }
    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, message)
    }
    pub fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "not found")
    }
    pub fn unauthorized() -> Self {
        Self::new(StatusCode::UNAUTHORIZED, "invalid or expired credentials")
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(serde_json::json!({"error":self.message}))).into_response()
    }
}
impl From<sqlx::Error> for ApiError {
    fn from(error: sqlx::Error) -> Self {
        tracing::error!(%error, "database operation failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database operation failed",
        )
    }
}
impl From<std::io::Error> for ApiError {
    fn from(error: std::io::Error) -> Self {
        tracing::error!(%error, "storage operation failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "storage operation failed",
        )
    }
}
pub(crate) async fn normalize(response: Response) -> Response {
    let mut response = if (response.status().is_client_error()
        || response.status().is_server_error())
        && !response
            .headers()
            .get("content-type")
            .is_some_and(|v| v.as_bytes().starts_with(b"application/json"))
    {
        let status = response.status();
        let mut replacement = ApiError::new(
            status,
            status.canonical_reason().unwrap_or("request failed"),
        )
        .into_response();
        for key in ["content-range", "retry-after", "www-authenticate"] {
            if let Some(value) = response.headers().get(key) {
                replacement
                    .headers_mut()
                    .insert(axum::http::HeaderName::from_static(key), value.clone());
            }
        }
        replacement
    } else {
        response
    };
    if response
        .headers()
        .get("content-type")
        .is_some_and(|v| v.as_bytes().starts_with(b"application/json"))
    {
        response
            .headers_mut()
            .insert("cache-control", "no-store".parse().unwrap());
    }
    response
        .headers_mut()
        .insert("x-content-type-options", "nosniff".parse().unwrap());
    response
}
