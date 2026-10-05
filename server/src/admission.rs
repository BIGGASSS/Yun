//! Admission is shared by every router clone, before extractors poll a body.
#[cfg(test)]
mod tests;

use crate::{ApiError, AppState, MAX_ARTWORK, MAX_CHUNK};
use axum::{
    body::{Body, Bytes, HttpBody},
    extract::{Request, State},
    http::{Method, StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use std::{
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::sync::OwnedSemaphorePermit;

const BYTE_UNIT: usize = 64 * 1024;

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
        return crate::error::normalize(busy().into_response()).await;
    };
    let Ok(bytes) = state
        .0
        .body_bytes
        .clone()
        .try_acquire_many_owned(limit.div_ceil(BYTE_UNIT) as u32)
    else {
        return crate::error::normalize(busy().into_response()).await;
    };
    let reservation = Admission(Arc::new(Reservations {
        _request: request_permit,
        _bytes: bytes,
    }));
    request.extensions_mut().insert(reservation.clone());
    let mut response = next.run(request).await;
    // Axum's serialized JSON body reports its actual buffered length. Charge
    // only the excess over the request reservation, rounded to 64 KiB units.
    // Do not use Content-Length: media streams may advertise an entire file
    // without buffering it. This does not bound transient handler/serialization
    // allocations, which have already happened before we see the response.
    let json_bytes = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .filter(|value| {
            value
                .split(';')
                .next()
                .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
        })
        .and_then(|_| response.body().size_hint().exact())
        .unwrap_or(0);
    let extra_units = json_bytes
        .div_ceil(BYTE_UNIT as u64)
        .saturating_sub(limit.div_ceil(BYTE_UNIT) as u64);
    let extra = if extra_units == 0 {
        None
    } else {
        let permit = u32::try_from(extra_units).ok().and_then(|units| {
            state
                .0
                .body_bytes
                .clone()
                .try_acquire_many_owned(units)
                .ok()
        });
        if permit.is_none() {
            // Discard the oversized body before creating the small error body;
            // retain the original reservation through that response's lifetime.
            drop(response);
            response = crate::error::normalize(busy().into_response()).await;
        }
        permit
    };
    // Handler completion is not response completion: buffered JSON can remain
    // unconsumed, or queued in Hyper behind a slow socket, after headers exist.
    // Both the base reservation and any excess follow the body and emitted Bytes.
    response.map(|body| with_reservation(body, Arc::new((reservation.0, extra))))
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
// This is a concurrency bound, not a slow-reader timeout. The serving path is
// axum::serve over Tokio TCP: Hyper queues Bytes for vectored writes. Keep the
// reservation in those Bytes too, because a single JSON frame can outlive its
// body while the socket is backpressured. Copies made by other transports or
// middleware are outside this ownership bound; proxy connection/write/idle
// limits remain necessary. Never release capacity on a poll_frame timer while
// the response (or its transport buffer) is still live.
pub(crate) fn with_permit(body: Body, permit: OwnedSemaphorePermit) -> Body {
    with_reservation(body, Arc::new(permit))
}
fn with_reservation<T: Send + Sync + 'static>(body: Body, reservation: Arc<T>) -> Body {
    if body.is_end_stream() {
        return body;
    }
    Body::new(PermittedBody {
        body,
        reservation: Some(reservation),
    })
}
struct PermittedBody<T> {
    body: Body,
    reservation: Option<Arc<T>>,
}
struct PermittedBytes<T> {
    bytes: Bytes,
    _reservation: Arc<T>,
}
impl<T> AsRef<[u8]> for PermittedBytes<T> {
    fn as_ref(&self) -> &[u8] {
        &self.bytes
    }
}
impl<T: Send + Sync + 'static> HttpBody for PermittedBody<T> {
    type Data = Bytes;
    type Error = axum::Error;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, Self::Error>>> {
        let result = Pin::new(&mut self.body).poll_frame(cx);
        let result = match result {
            Poll::Ready(Some(Ok(frame))) => {
                Poll::Ready(Some(Ok(frame.map_data(|bytes| match &self.reservation {
                    Some(reservation) if !bytes.is_empty() => Bytes::from_owner(PermittedBytes {
                        bytes,
                        _reservation: reservation.clone(),
                    }),
                    _ => bytes,
                }))))
            }
            result => result,
        };
        if matches!(result, Poll::Ready(None | Some(Err(_)))) || self.body.is_end_stream() {
            self.reservation.take();
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
