package com.ryanheise.audioservice;

/** Actual service state, committed only after successful platform operations. */
final class AudioServiceLifecycle {
    private boolean playing;
    private boolean foreground;

    boolean isPlaying() {
        return playing;
    }

    boolean isForeground() {
        return foreground;
    }

    void update(boolean requestedPlaying, boolean stopForegroundOnPause,
            Runnable enterForeground, Runnable exitForeground) {
        if (requestedPlaying && !foreground) {
            // A rejected promotion must leave both flags unchanged. A later
            // explicit Dart recovery can retry; this class never schedules work.
            enterForeground.run();
            foreground = true;
        } else if (!requestedPlaying && foreground && stopForegroundOnPause) {
            exitForeground.run();
            foreground = false;
        }
        playing = requestedPlaying;
    }

    void stop(Runnable exitForeground) {
        if (foreground) exitForeground.run();
        reset();
    }

    void reset() {
        playing = false;
        foreground = false;
    }
}
