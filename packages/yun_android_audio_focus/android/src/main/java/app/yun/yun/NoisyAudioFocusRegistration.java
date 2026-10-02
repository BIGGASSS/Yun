package app.yun.yun;

/** Couples route-unplug listening to one active native focus registration. */
final class NoisyAudioFocusRegistration implements AudioFocusCoordinator.Registration {
    interface Receiver {
        void register();
        void unregister();
    }

    private final AudioFocusCoordinator.Registration focus;
    private final Receiver receiver;
    private boolean listening;
    private boolean focusReleased;

    NoisyAudioFocusRegistration(AudioFocusCoordinator.Registration focus, Receiver receiver) {
        this.focus = focus;
        this.receiver = receiver;
    }

    @Override
    public AudioFocusCoordinator.Result request() {
        AudioFocusCoordinator.Result result = focus.request();
        if (result != AudioFocusCoordinator.Result.FAILED) {
            // A failed register call may have partially installed the receiver.
            // Cleanup must attempt both resources even in that case.
            listening = true;
            receiver.register();
        }
        return result;
    }

    @Override
    public boolean abandon() {
        // Unplug monitoring stops even if OS focus abandonment fails. Keep the
        // two cleanup results separate so either failure remains retryable.
        boolean receiverReleased = true;
        if (listening) {
            try {
                receiver.unregister();
                listening = false;
            } catch (RuntimeException error) {
                receiverReleased = false;
            }
        }
        if (!focusReleased) {
            try {
                focusReleased = focus.abandon();
            } catch (RuntimeException error) {
                focusReleased = false;
            }
        }
        return receiverReleased && focusReleased;
    }
}
