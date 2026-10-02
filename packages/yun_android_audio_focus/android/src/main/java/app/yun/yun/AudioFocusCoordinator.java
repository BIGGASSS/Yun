package app.yun.yun;

/**
 * One focus registration per Flutter engine. All methods and callbacks run on
 * the platform thread. Kept Android-free so cancellation races run on the JVM.
 */
final class AudioFocusCoordinator {
    enum Result { GRANTED, DELAYED, FAILED }
    enum Change { GAIN, LOSS, TRANSIENT_LOSS, NOISY }

    interface Listener {
        void onChange(Change change);
    }

    interface Registration {
        Result request();
        boolean abandon();
    }

    interface Platform {
        Registration prepare(Listener listener);
    }

    interface Events {
        void onChange(long requestId, Change change);
    }

    private static final class Request {
        final long id;
        Registration registration;

        Request(long id) {
            this.id = id;
        }
    }

    private final Platform platform;
    private final Events events;
    private Request active;
    private Request retiring;
    private boolean disposed;

    AudioFocusCoordinator(Platform platform, Events events) {
        this.platform = platform;
        this.events = events;
    }

    Result request(long requestId) {
        if (disposed) return Result.FAILED;
        if (!abandon()) return Result.FAILED;
        Request pending = new Request(requestId);
        active = pending;
        try {
            pending.registration = platform.prepare(change -> onChange(pending, change));
            Result result = pending.registration.request();
            // Also fail closed if a platform callback invalidated this request
            // during acquisition. A later request may already be active.
            if (active != pending) return Result.FAILED;
            if (result == Result.FAILED) {
                active = null;
                release(pending);
            }
            return result;
        } catch (RuntimeException error) {
            if (active == pending) active = null;
            release(pending);
            return Result.FAILED;
        }
    }

    boolean abandon() {
        Request previous = active;
        // Invalidate before native abandonment, which may itself cause callbacks.
        active = null;
        return release(previous);
    }

    void dispose() {
        disposed = true;
        abandon();
    }

    private void onChange(Request request, Change change) {
        // Listener identity matters as well as the client ID. Android may deliver
        // an already-queued gain after cancel, replacement or permanent loss.
        if (disposed || active != request) return;
        if (change == Change.LOSS || change == Change.NOISY) {
            active = null;
            release(request);
        }
        events.onChange(request.id, change);
    }

    private boolean release(Request request) {
        // Retain a failed cleanup for the next abandon/request/dispose, without
        // leaving its listener active. Never claim a retry succeeded merely
        // because active was already invalidated by the first attempt.
        if (request != null && request.registration != null) retiring = request;
        Request previous = retiring;
        if (previous == null) return true;
        try {
            boolean released = previous.registration.abandon();
            if (released) retiring = null;
            return released;
        } catch (RuntimeException error) {
            return false;
        }
    }
}
