package com.ryanheise.audioservice;

/** Deterministic tests of the production connection coordinator; no Android SDK. */
public final class AudioServiceConnectionTest {
    public static void main(String[] args) {
        failureBeforeConfigureRetriesExplicitly();
        failedConfigureRetiresOldCallbacks();
        duplicateConfigureDoesNotReplaceResult();
        ownerDetachRetiresPendingResult();
        newEngineConfigurationOwnsBrowser(false);
        newEngineConfigurationOwnsBrowser(true);
        synchronousConnectCallbacksAndThrows();
        resultReentryCannotClearNewAttempt();
        suspensionRetiresOnlyUnconfiguredConnection();
        cleanupThrowCannotDeliverResultTwice();
        System.out.println("AudioServiceConnectionTest: 10 tests passed");
    }

    private static void failureBeforeConfigureRetriesExplicitly() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend backend = new Backend(state);
        state.ensureConnected(backend);
        long failed = backend.generation;
        state.failed(failed, "initial bind failed");
        check(backend.connects == 1 && backend.disconnects == 1, "failure must not retry");
        Result result = new Result();
        state.configure(backend, result);
        check(backend.connects == 2 && result.calls() == 0, "explicit configure reconnects once");
        state.connected(backend.generation);
        check(result.successes == 1 && result.errors == 0, "retry succeeds");
        state.connected(backend.generation);
        check(result.calls() == 1, "repeated success cannot reply twice");
        Result later = new Result();
        state.configure(backend, later);
        check(later.successes == 1 && backend.connects == 2, "configured service reused");
    }

    private static void failedConfigureRetiresOldCallbacks() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend backend = new Backend(state);
        Result first = new Result();
        state.configure(backend, first);
        long old = backend.generation;
        state.failed(old, "bind failed");
        check(first.errors == 1 && !state.isConfiguring(), "failed result consumed");
        Result retry = new Result();
        state.configure(backend, retry);
        long current = backend.generation;
        state.failed(old, "stale failure");
        state.connected(old);
        check(retry.calls() == 0 && state.isCurrent(current), "old callbacks cannot finish new result");
        check(backend.disconnects == 1, "old failure cannot disconnect new browser");
        state.connected(current);
        check(first.calls() == 1 && retry.successes == 1, "each result completed once");
    }

    private static void duplicateConfigureDoesNotReplaceResult() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend backend = new Backend(state);
        Result first = new Result();
        Result duplicate = new Result();
        state.configure(backend, first);
        state.configure(backend, duplicate);
        check(duplicate.errors == 1 && first.calls() == 0, "duplicate rejected independently");
        check(backend.connects == 1, "no concurrent second browser");
        state.connected(backend.generation);
        check(first.successes == 1 && duplicate.calls() == 1, "pending result not overwritten");
    }

    private static void ownerDetachRetiresPendingResult() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend oldBackend = new Backend(state);
        Backend newBackend = new Backend(state);
        Result oldResult = new Result();
        state.configure(oldBackend, oldResult);
        long old = oldBackend.generation;
        state.detached(oldBackend, "engine detached");
        check(oldResult.errors == 1 && oldBackend.disconnects == 1, "detach retires result and browser");
        Result current = new Result();
        state.configure(newBackend, current);
        state.detached(oldBackend, "late old detach");
        state.connected(old);
        state.failed(old, "late old failure");
        check(newBackend.disconnects == 0 && current.calls() == 0, "old owner cannot retire new engine");
        state.connected(newBackend.generation);
        check(current.successes == 1 && oldResult.calls() == 1, "only current owner succeeds");
    }

    private static void newEngineConfigurationOwnsBrowser(boolean initiallyConnected) {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend oldOwner = new Backend(state);
        Backend newOwner = new Backend(state);
        state.ensureConnected(oldOwner);
        long old = oldOwner.generation;
        if (initiallyConnected) state.connected(old);
        Result next = new Result();
        state.configure(newOwner, next);
        check(oldOwner.disconnects == 1 && newOwner.connects == 1, "explicit engine takeover rebuilds once");
        check(next.calls() == 0 && state.isCurrent(newOwner.generation), "new engine owns pending connection");
        state.detached(oldOwner, "old engine detached while binding");
        state.failed(old, "old failure");
        state.connected(old);
        check(newOwner.disconnects == 0 && next.calls() == 0, "old engine cannot invalidate takeover");
        state.connected(newOwner.generation);
        state.detached(oldOwner, "old engine detached after takeover");
        check(next.successes == 1 && state.isConnected(), "new handler survives old engine detach");
        Result again = new Result();
        state.configure(newOwner, again);
        check(again.successes == 1 && newOwner.connects == 1, "same engine reuses active browser");
    }

    private static void synchronousConnectCallbacksAndThrows() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend backend = new Backend(state);
        backend.throwDuringConnect = true;
        Result failed = new Result();
        state.configure(backend, failed);
        check(failed.errors == 1 && backend.disconnects == 1, "synchronous connect throw retires result");
        backend.throwDuringConnect = false;
        backend.succeedDuringConnect = true;
        Result success = new Result();
        state.configure(backend, success);
        check(success.successes == 1 && state.isConnected(), "synchronous connection callback sees pending result");
        state.disconnect("test reset");
        backend.succeedDuringConnect = false;
        backend.failDuringConnect = true;
        backend.throwDuringConnect = true;
        Result doubleFailure = new Result();
        state.configure(backend, doubleFailure);
        check(doubleFailure.errors == 1, "callback failure then connect throw replies once");
        check(!state.isConfiguring() && !state.isConnected(), "synchronous failures leave no pending state");
    }

    private static void resultReentryCannotClearNewAttempt() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend oldBackend = new Backend(state);
        Backend newBackend = new Backend(state);
        Result retry = new Result();
        Result failed = new Result() {
            @Override
            public void error(String message) {
                super.error(message);
                state.configure(newBackend, retry);
            }
        };
        state.configure(oldBackend, failed);
        long old = oldBackend.generation;
        state.failed(old, "failed");
        check(oldBackend.disconnects == 1 && newBackend.connects == 1, "cleanup precedes reentrant retry");
        state.failed(old, "old duplicate");
        check(state.isCurrent(newBackend.generation), "old callback cannot clear reentrant attempt");
        state.connected(newBackend.generation);
        check(failed.errors == 1 && retry.successes == 1, "reentrant results finish once");
    }

    private static void suspensionRetiresOnlyUnconfiguredConnection() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend backend = new Backend(state);
        Result first = new Result();
        state.configure(backend, first);
        long old = backend.generation;
        check(state.suspended(old), "pending suspension handled");
        check(first.errors == 1 && backend.disconnects == 1, "suspension clears pending configuration");
        Result retry = new Result();
        state.configure(backend, retry);
        check(state.suspended(old), "stale suspension ignored");
        check(retry.calls() == 0 && backend.disconnects == 1, "stale suspension preserves newer browser");
        state.connected(backend.generation);
        check(!state.suspended(backend.generation), "initialized suspension keeps upstream behavior");
        check(state.isConnected() && retry.calls() == 1, "no reset after successful configuration");
    }

    private static void cleanupThrowCannotDeliverResultTwice() {
        AudioServiceConnection state = new AudioServiceConnection();
        Backend backend = new Backend(state);
        backend.throwDuringConnect = true;
        backend.throwDuringDisconnect = true;
        Result first = new Result();
        state.configure(backend, first);
        check(first.errors == 1 && !state.isConfiguring(), "cleanup failure preserves single original error");
        backend.throwDuringConnect = false;
        backend.throwDuringDisconnect = false;
        Result retry = new Result();
        state.configure(backend, retry);
        state.connected(backend.generation);
        check(first.calls() == 1 && retry.successes == 1, "cleanup failure cannot poison explicit retry");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static final class Backend implements AudioServiceConnection.Backend {
        final AudioServiceConnection state;
        int connects;
        int disconnects;
        long generation;
        boolean succeedDuringConnect;
        boolean failDuringConnect;
        boolean throwDuringConnect;
        boolean throwDuringDisconnect;

        Backend(AudioServiceConnection state) {
            this.state = state;
        }

        @Override
        public void connect(long generation) {
            connects++;
            this.generation = generation;
            if (succeedDuringConnect) state.connected(generation);
            if (failDuringConnect) state.failed(generation, "callback failure");
            if (throwDuringConnect) throw new IllegalStateException("connect failed");
        }

        @Override
        public void disconnect() {
            disconnects++;
            if (throwDuringDisconnect) throw new IllegalStateException("disconnect failed");
        }
    }

    private static class Result implements AudioServiceConnection.Result {
        int successes;
        int errors;

        int calls() {
            return successes + errors;
        }

        @Override
        public void success() {
            successes++;
            check(calls() == 1, "result delivered more than once");
        }

        @Override
        public void error(String message) {
            errors++;
            check(calls() == 1, "result delivered more than once");
        }
    }
}
