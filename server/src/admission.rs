//! Admission is shared by every router clone, before extractors poll a body.
use crate::{ApiError, AppState, MAX_ARTWORK, MAX_CHUNK};
use axum::{
    body::{Body, Bytes, HttpBody},
    extract::{Request, State},
    http::{Method, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use std::{
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::sync::OwnedSemaphorePermit;

#[derive(Clone)]
pub(crate) struct Admission(pub Arc<Reservations>);
pub(crate) struct Reservations {
    _request: OwnedSemaphorePermit,
    _bytes: OwnedSemaphorePermit,
}

pub(crate) async fn admit(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Response {
    // Reserve the route maximum, not an untrusted Content-Length. This also bounds
    // chunked/unknown-length bodies without waiting while partially buffered.
    let path = request.uri().path();
    let limit = if request.method() == Method::PUT
        && path.starts_with("/api/v1/tracks/")
        && path.ends_with("/artwork")
    {
        MAX_ARTWORK
    } else if request.method() == Method::PATCH && path.starts_with("/api/v1/uploads/") {
        MAX_CHUNK
    } else {
        2 * 1024 * 1024
    };
    let Ok(request_permit) = state.0.requests.clone().try_acquire_owned() else {
        return busy().into_response();
    };
    let Ok(bytes) = state
        .0
        .body_bytes
        .clone()
        .try_acquire_many_owned(limit.div_ceil(64 * 1024) as u32)
    else {
        return busy().into_response();
    };
    let reservation = Admission(Arc::new(Reservations {
        _request: request_permit,
        _bytes: bytes,
    }));
    request.extensions_mut().insert(reservation.clone());
    let response = next.run(request).await;
    drop(reservation);
    response
}
fn busy() -> ApiError {
    ApiError::new(
        StatusCode::TOO_MANY_REQUESTS,
        "server capacity reached; retry later",
    )
}

pub(crate) fn stream_permit(state: &AppState) -> Result<OwnedSemaphorePermit, ApiError> {
    state
        .0
        .streams
        .clone()
        .try_acquire_owned()
        .map_err(|_| busy())
}
// Retained until EOF, error, or drop, not merely until response headers exist.
// This is a concurrency bound, not a slow-reader timeout: Hyper can stop polling
// this body under socket backpressure. A poll_frame timer cannot abort that
// transport, and releasing the permit while it remains live breaks the bound.
// Downstream write/idle timeouts must be enforced by the proxy/transport owner.
pub(crate) fn with_permit(body: Body, permit: OwnedSemaphorePermit) -> Body {
    Body::new(PermittedBody {
        body,
        permit: Some(permit),
    })
}
struct PermittedBody {
    body: Body,
    permit: Option<OwnedSemaphorePermit>,
}
impl HttpBody for PermittedBody {
    type Data = Bytes;
    type Error = axum::Error;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, Self::Error>>> {
        let result = Pin::new(&mut self.body).poll_frame(cx);
        if matches!(result, Poll::Ready(None | Some(Err(_)))) || self.body.is_end_stream() {
            self.permit.take();
        }
        result
    }
    fn is_end_stream(&self) -> bool {
        self.body.is_end_stream()
    }
    fn size_hint(&self) -> http_body::SizeHint {
        self.body.size_hint()
    }
}
