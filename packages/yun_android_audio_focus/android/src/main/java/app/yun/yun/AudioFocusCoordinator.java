package app.yun.yun;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * One focus registration per Flutter engine. All methods and callbacks run on
 * the platform thread. Kept Android-free so cancellation races run on the JVM.
 */
final class AudioFocusCoordinator {
    enum Result { GRANTED, DELAYED, FAILED }
    enum Change { GAIN, LOSS, TRANSIENT_LOSS, NOISY }

    /** Fixed vocabulary: never include exception messages, media or account data. */
    enum Category {
        BRIDGE_PREPARE("bridge_prepare"), NATIVE_REQUEST("native_request"),
        NOISY_REGISTER("noisy_register"), NOISY_UNREGISTER("noisy_unregister"),
        NATIVE_ABANDON("native_abandon"), REQUEST("request"), ABANDON("abandon"),
        BRIDGE_CHANNEL("bridge_channel");

        final String wireName;
        Category(String wireName) { this.wireName = wireName; }
    }

    enum Outcome {
        GRANTED("granted"), DELAYED("delayed"), FAILED("failed"),
        SUCCESS("success"), ERROR("error"), CANCELLED("cancelled"),
        CLEANUP_BLOCKED("cleanup_blocked"), DISPOSED("disposed");

        final String wireName;
        Outcome(String wireName) { this.wireName = wireName; }

        static Outcome from(Result result) {
            switch (result) {
                case GRANTED: return GRANTED;
                case DELAYED: return DELAYED;
                default: return FAILED;
            }
        }
    }

    static final class Diagnostic {
        final long requestId;
        final Category category;
        final Outcome result;
        final String exceptionClass;

        Diagnostic(long requestId, Category category, Outcome result, RuntimeException error) {
            this.requestId = requestId;
            this.category = category;
            this.result = result;
            // getMessage(), toString(), causes and stack traces may contain URLs
            // or credentials. Only the class name crosses this boundary.
            exceptionClass = error == null ? null : error.getClass().getName();
        }

        Map<String, Object> toMap() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("requestId", requestId);
            values.put("category", category.wireName);
            values.put("result", result.wireName);
            if (exceptionClass != null) values.put("exceptionClass", exceptionClass);
            return values;
        }

        String logLine() {
            return "category=" + category.wireName + " requestId=" + requestId
                    + " result=" + result.wireName
                    + (exceptionClass == null ? "" : " exceptionClass=" + exceptionClass);
        }
    }

    interface DiagnosticSink {
        void onDiagnostic(Diagnostic diagnostic);
    }

    /** Per-registration, request-ID-bound diagnostic reporter. */
    interface Diagnostics {
        void record(Category category, Outcome result, RuntimeException error);
    }

    static final Diagnostics NO_DIAGNOSTICS = (category, result, error) -> {};

    interface Listener {
        void onChange(Change change);
    }

    interface Registration {
        Result request();
        boolean abandon();
        default void setDiagnostics(Diagnostics diagnostics) {}
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
    private final DiagnosticSink diagnostics;
    private Request active;
    private Request retiring;
    private boolean disposed;

    AudioFocusCoordinator(Platform platform, Events events) {
        this(platform, events, diagnostic -> {});
    }

    AudioFocusCoordinator(Platform platform, Events events, DiagnosticSink diagnostics) {
        this.platform = platform;
        this.events = events;
        this.diagnostics = diagnostics;
    }

    Result request(long requestId) {
        if (disposed) {
            record(requestId, Category.REQUEST, Outcome.DISPOSED, null);
            return Result.FAILED;
        }
        if (!abandon()) {
            record(requestId, Category.REQUEST, Outcome.CLEANUP_BLOCKED, null);
            return Result.FAILED;
        }
        Request pending = new Request(requestId);
        active = pending;
        Category stage = Category.BRIDGE_PREPARE;
        try {
            pending.registration = platform.prepare(change -> onChange(pending, change));
            pending.registration.setDiagnostics(
                    (category, result, error) -> record(requestId, category, result, error));
            stage = Category.REQUEST;
            Result result = pending.registration.request();
            // Also fail closed if a platform callback invalidated this request
            // during acquisition. A later request may already be active.
            if (active != pending) {
                record(requestId, Category.REQUEST, Outcome.CANCELLED, null);
                return Result.FAILED;
            }
            record(requestId, Category.REQUEST, Outcome.from(result), null);
            if (result == Result.FAILED) {
                active = null;
                release(pending);
            }
            return result;
        } catch (RuntimeException error) {
            record(requestId, stage, Outcome.ERROR, error);
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
            record(previous.id, Category.ABANDON,
                    released ? Outcome.SUCCESS : Outcome.FAILED, null);
            if (released) retiring = null;
            return released;
        } catch (RuntimeException error) {
            record(previous.id, Category.ABANDON, Outcome.ERROR, error);
            return false;
        }
    }

    private void record(long requestId, Category category, Outcome result, RuntimeException error) {
        try {
            diagnostics.onDiagnostic(new Diagnostic(requestId, category, result, error));
        } catch (RuntimeException ignored) {
            // Telemetry must never acquire, retain, abandon or grant focus.
        }
    }
}
