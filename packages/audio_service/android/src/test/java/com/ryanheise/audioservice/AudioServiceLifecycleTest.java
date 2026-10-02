package com.ryanheise.audioservice;

/** Exercises the production service lifecycle without an Android runtime. */
public final class AudioServiceLifecycleTest {
    public static void main(String[] args) {
        failedPromotionRemainsRetryable();
        retainedForegroundSurvivesTrackChangesAndPause();
        stoppingForegroundRequiresNewPromotion();
        rejectedPausePreservesActualState();
        System.out.println("AudioServiceLifecycleTest: 4 tests passed");
    }

    private static void failedPromotionRemainsRetryable() {
        AudioServiceLifecycle state = new AudioServiceLifecycle();
        int[] starts = {0};
        RuntimeException denial = new IllegalStateException("OS denied start");
        Runnable denied = () -> { starts[0]++; throw denial; };
        for (int command = 0; command < 2; command++) {
            try {
                state.update(true, false, denied, () -> {});
                throw new AssertionError("denial must reach caller");
            } catch (RuntimeException error) {
                check(error == denial, "preserves original failure");
            }
            check(!state.isPlaying() && !state.isForeground(), "failure cannot set native flags");
            check(starts[0] == command + 1, "one attempt, no automatic retries");
        }
        state.update(true, false, () -> starts[0]++, () -> {});
        check(starts[0] == 3 && state.isPlaying() && state.isForeground(), "explicit recovery promotes");
    }

    private static void retainedForegroundSurvivesTrackChangesAndPause() {
        AudioServiceLifecycle state = new AudioServiceLifecycle();
        int[] calls = {0, 0};
        Runnable enter = () -> calls[0]++;
        Runnable exit = () -> calls[1]++;
        state.update(true, false, enter, exit);
        for (int track = 0; track < 100; track++) state.update(true, false, enter, exit);
        state.update(false, false, enter, exit);
        check(!state.isPlaying() && state.isForeground(), "paused session remains foreground");
        state.update(true, false, enter, exit);
        check(calls[0] == 1 && calls[1] == 0, "continuous play/resume never restarts retained service");
        state.stop(exit);
        state.stop(exit);
        check(calls[1] == 1 && !state.isPlaying() && !state.isForeground(), "stop releases once");
        state.update(true, false, enter, exit);
        check(calls[0] == 2, "new session promotes after stop");
    }

    private static void stoppingForegroundRequiresNewPromotion() {
        AudioServiceLifecycle state = new AudioServiceLifecycle();
        int[] calls = {0, 0};
        Runnable enter = () -> calls[0]++;
        Runnable exit = () -> calls[1]++;
        state.update(true, true, enter, exit);
        state.update(false, true, enter, exit);
        check(!state.isPlaying() && !state.isForeground(), "configured pause demotes");
        state.update(true, true, enter, exit);
        check(calls[0] == 2 && calls[1] == 1, "resume legitimately needs promotion");
        state.reset();
        check(!state.isPlaying() && !state.isForeground(), "destroy resets flags");
    }

    private static void rejectedPausePreservesActualState() {
        AudioServiceLifecycle state = new AudioServiceLifecycle();
        state.update(true, true, () -> {}, () -> {});
        try {
            state.update(false, true, () -> {}, () -> { throw new IllegalStateException(); });
            throw new AssertionError("demotion failure must reach caller");
        } catch (IllegalStateException expected) {
            check(state.isPlaying() && state.isForeground(), "failed demotion does not lie about flags");
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
