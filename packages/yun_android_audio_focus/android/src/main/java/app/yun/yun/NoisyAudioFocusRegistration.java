package app.yun.yun;

/** Couples route-unplug listening to one active native focus registration. */
final class NoisyAudioFocusRegistration implements AudioFocusCoordinator.Registration {
    interface Receiver {
        void register();
        void unregister();
    }

    private final AudioFocusCoordinator.Registration focus;
    private final Receiver receiver;
    private AudioFocusCoordinator.Diagnostics diagnostics = AudioFocusCoordinator.NO_DIAGNOSTICS;
    private boolean listening;
    private boolean focusReleased;

    NoisyAudioFocusRegistration(AudioFocusCoordinator.Registration focus, Receiver receiver) {
        this.focus = focus;
        this.receiver = receiver;
    }

    @Override
    public void setDiagnostics(AudioFocusCoordinator.Diagnostics diagnostics) {
        this.diagnostics = diagnostics;
    }

    @Override
    public AudioFocusCoordinator.Result request() {
        AudioFocusCoordinator.Result result;
        try {
            result = focus.request();
            diagnostics.record(AudioFocusCoordinator.Category.NATIVE_REQUEST,
                    AudioFocusCoordinator.Outcome.from(result), null);
        } catch (RuntimeException error) {
            diagnostics.record(AudioFocusCoordinator.Category.NATIVE_REQUEST,
                    AudioFocusCoordinator.Outcome.ERROR, error);
            throw error;
        }
        if (result != AudioFocusCoordinator.Result.FAILED) {
            // A failed register call may have partially installed the receiver.
            // Cleanup must attempt both resources even in that case.
            listening = true;
            try {
                receiver.register();
                diagnostics.record(AudioFocusCoordinator.Category.NOISY_REGISTER,
                        AudioFocusCoordinator.Outcome.SUCCESS, null);
            } catch (RuntimeException error) {
                diagnostics.record(AudioFocusCoordinator.Category.NOISY_REGISTER,
                        AudioFocusCoordinator.Outcome.ERROR, error);
                throw error;
            }
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
                diagnostics.record(AudioFocusCoordinator.Category.NOISY_UNREGISTER,
                        AudioFocusCoordinator.Outcome.SUCCESS, null);
            } catch (IllegalArgumentException alreadyUnregistered) {
                // Android uses this when registration failed before installation.
                // No receiver remains, but retain the exception class in evidence.
                listening = false;
                diagnostics.record(AudioFocusCoordinator.Category.NOISY_UNREGISTER,
                        AudioFocusCoordinator.Outcome.SUCCESS, alreadyUnregistered);
            } catch (RuntimeException error) {
                receiverReleased = false;
                diagnostics.record(AudioFocusCoordinator.Category.NOISY_UNREGISTER,
                        AudioFocusCoordinator.Outcome.ERROR, error);
            }
        }
        if (!focusReleased) {
            try {
                focusReleased = focus.abandon();
                diagnostics.record(AudioFocusCoordinator.Category.NATIVE_ABANDON,
                        focusReleased ? AudioFocusCoordinator.Outcome.SUCCESS
                                : AudioFocusCoordinator.Outcome.FAILED, null);
            } catch (RuntimeException error) {
                focusReleased = false;
                diagnostics.record(AudioFocusCoordinator.Category.NATIVE_ABANDON,
                        AudioFocusCoordinator.Outcome.ERROR, error);
            }
        }
        return receiverReleased && focusReleased;
    }
}
