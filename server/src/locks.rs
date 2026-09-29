//! Enable `yun_server::locks=debug` to measure global lock wait/hold time.
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, MutexGuard};

#[derive(Default)]
pub(crate) struct WriteLock(Mutex<()>);
impl WriteLock {
    pub(crate) async fn lock(&self) -> WriteGuard<'_> {
        let waiting = Instant::now();
        let guard = self.0.lock().await;
        WriteGuard {
            _guard: guard,
            wait: waiting.elapsed(),
            acquired: Instant::now(),
        }
    }
}
pub(crate) struct WriteGuard<'a> {
    _guard: MutexGuard<'a, ()>,
    wait: Duration,
    acquired: Instant,
}
impl Drop for WriteGuard<'_> {
    fn drop(&mut self) {
        tracing::debug!(
            wait_us = self.wait.as_micros() as u64,
            hold_us = self.acquired.elapsed().as_micros() as u64,
            "global write lock"
        );
    }
}
