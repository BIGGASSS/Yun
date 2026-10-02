package com.ryanheise.audioservice;

/** Owns one browser generation and consumes each configure result at most once. */
final class AudioServiceConnection {
    interface Backend {
        void connect(long generation);
        void disconnect();
    }

    interface Result {
        void success();
        void error(String message);
    }

    private long generation;
    private Backend backend;
    private Backend pendingOwner;
    private Result pendingResult;
    private boolean connected;

    boolean isCurrent(long candidate) {
        return backend != null && generation == candidate;
    }

    boolean isConnected() {
        return connected;
    }

    boolean isConfiguring() {
        return pendingResult != null;
    }

    void ensureConnected(Backend owner) {
        if (backend != null) return;
        backend = owner;
        final long attempt = ++generation;
        try {
            owner.connect(attempt);
        } catch (RuntimeException error) {
            failed(attempt, "Unable to bind to AudioService: " + error.getMessage());
        }
    }

    void configure(Backend owner, Result result) {
        if (pendingResult != null) {
            result.error("AudioService configuration is already in progress.");
            return;
        }
        if (backend != null && backend != owner) {
            // configure also transfers the native handler to this engine. Give
            // it its own browser callbacks/context so detaching the old engine
            // cannot invalidate the new handler's shared connection.
            disconnect("AudioService configuration moved to another engine.");
        }
        if (connected) {
            result.success();
            return;
        }
        pendingOwner = owner;
        pendingResult = result;
        // Only an explicit configure or the existing attachment path starts a
        // connection. Failure never schedules a retry or a polling loop.
        ensureConnected(owner);
    }

    void connected(long attempt) {
        if (!isCurrent(attempt)) return;
        connected = true;
        final Result result = takePendingResult();
        if (result != null) result.success();
    }

    void failed(long attempt, String message) {
        if (!isCurrent(attempt)) return;
        disconnect(message);
    }

    boolean suspended(long attempt) {
        if (!isCurrent(attempt)) return true;
        if (connected) return false;
        failed(attempt, "AudioService connection suspended during configuration.");
        return true;
    }

    void detached(Backend owner, String message) {
        if (backend == owner) {
            disconnect(message);
        } else if (pendingOwner == owner) {
            // Another engine owns this browser. Retire only the detached
            // caller's result, without disrupting that engine's connection.
            final Result result = takePendingResult();
            if (result != null) result.error(message);
        }
    }

    void disconnect(String message) {
        final Backend previousBackend = backend;
        final Result result = takePendingResult();
        // Invalidate callbacks and clear ownership before native disconnect or
        // result delivery can synchronously re-enter this coordinator.
        ++generation;
        backend = null;
        connected = false;
        try {
            if (previousBackend != null) previousBackend.disconnect();
        } catch (RuntimeException cleanupError) {
            // Ownership is already retired. Do not let cleanup failure escape
            // into the method-channel catch and deliver this result twice.
            System.err.println("AudioService disconnect cleanup failed: " + cleanupError.getMessage());
        } finally {
            if (result != null) result.error(message);
        }
    }

    private Result takePendingResult() {
        final Result result = pendingResult;
        pendingResult = null;
        pendingOwner = null;
        return result;
    }
}
