package app.yun.yun;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

public final class NoisyAudioFocusRegistrationTest {
    private static int passed;

    private static final class Fixture {
        AudioFocusCoordinator.Result result = AudioFocusCoordinator.Result.GRANTED;
        boolean failRegister;
        boolean failUnregister;
        boolean failAbandon;
        boolean releaseFocus = true;
        int registers;
        int unregisters;
        int abandons;
        final List<String> operations = new ArrayList<>();
        final NoisyAudioFocusRegistration registration = new NoisyAudioFocusRegistration(
                new AudioFocusCoordinator.Registration() {
                    @Override
                    public AudioFocusCoordinator.Result request() {
                        operations.add("request");
                        return result;
                    }

                    @Override
                    public boolean abandon() {
                        operations.add("abandon");
                        abandons++;
                        if (failAbandon) throw new IllegalStateException("focus cleanup failed");
                        return releaseFocus;
                    }
                }, new NoisyAudioFocusRegistration.Receiver() {
                    @Override
                    public void register() {
                        operations.add("register");
                        registers++;
                        if (failRegister) throw new IllegalStateException("register failed");
                    }

                    @Override
                    public void unregister() {
                        operations.add("unregister");
                        unregisters++;
                        if (failUnregister) throw new IllegalStateException("unregister failed");
                    }
                });
    }

    private static void equal(Object expected, Object actual) {
        if (!Objects.equals(expected, actual)) {
            throw new AssertionError("Expected " + expected + ", got " + actual);
        }
    }

    private static void test(String name, Runnable body) {
        body.run();
        passed++;
        System.out.println("PASS " + name);
    }

    public static void main(String[] args) {
        test("idle adapter owns no broadcast receiver", () -> {
            Fixture f = new Fixture();
            equal(0, f.registers);
            equal(0, f.unregisters);
        });
        for (AudioFocusCoordinator.Result accepted : Arrays.asList(
                AudioFocusCoordinator.Result.GRANTED, AudioFocusCoordinator.Result.DELAYED)) {
            test(accepted + " registration monitors unplug and abandons once", () -> {
                Fixture f = new Fixture();
                f.result = accepted;
                equal(accepted, f.registration.request());
                equal(1, f.registers);
                equal(true, f.registration.abandon());
                equal(true, f.registration.abandon());
                equal(1, f.unregisters);
                equal(1, f.abandons);
                equal(Arrays.asList("request", "register", "unregister", "abandon"), f.operations);
            });
        }
        test("denied focus never leaves an unplug receiver registered", () -> {
            Fixture f = new Fixture();
            f.result = AudioFocusCoordinator.Result.FAILED;
            equal(AudioFocusCoordinator.Result.FAILED, f.registration.request());
            equal(true, f.registration.abandon());
            equal(0, f.registers);
            equal(0, f.unregisters);
            equal(1, f.abandons);
        });
        test("failed receiver registration fails acquisition and cleans both resources", () -> {
            Fixture f = new Fixture();
            f.failRegister = true;
            AudioFocusCoordinator owner = new AudioFocusCoordinator(
                    listener -> f.registration, (id, change) -> {});
            equal(AudioFocusCoordinator.Result.FAILED, owner.request(1));
            equal(1, f.registers);
            equal(1, f.unregisters);
            equal(1, f.abandons);
        });
        test("receiver is removed even when native focus cleanup fails", () -> {
            Fixture f = new Fixture();
            f.registration.request();
            f.releaseFocus = false;
            equal(false, f.registration.abandon());
            equal(1, f.unregisters);
            f.releaseFocus = true;
            equal(true, f.registration.abandon());
            equal(1, f.unregisters);
            equal(2, f.abandons);
        });
        test("failed receiver cleanup retries without abandoning focus twice", () -> {
            Fixture f = new Fixture();
            f.registration.request();
            f.failUnregister = true;
            equal(false, f.registration.abandon());
            equal(1, f.abandons);
            f.failUnregister = false;
            equal(true, f.registration.abandon());
            equal(2, f.unregisters);
            equal(1, f.abandons);
        });
        test("exceptions in both cleanup paths remain independently retryable", () -> {
            Fixture f = new Fixture();
            f.registration.request();
            f.failUnregister = true;
            f.failAbandon = true;
            equal(false, f.registration.abandon());
            equal(1, f.unregisters);
            equal(1, f.abandons);
            f.failUnregister = false;
            f.failAbandon = false;
            equal(true, f.registration.abandon());
            equal(2, f.unregisters);
            equal(2, f.abandons);
        });
        test("engine detach unregisters an active route listener", () -> {
            Fixture f = new Fixture();
            AudioFocusCoordinator owner = new AudioFocusCoordinator(
                    listener -> f.registration, (id, change) -> {});
            owner.request(1);
            owner.dispose();
            equal(1, f.unregisters);
            equal(1, f.abandons);
        });
        System.out.println(passed + " noisy receiver lifecycle JVM tests passed");
    }
}
