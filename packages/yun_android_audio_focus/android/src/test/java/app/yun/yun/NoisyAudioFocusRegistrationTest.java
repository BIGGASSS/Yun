package app.yun.yun;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

public final class NoisyAudioFocusRegistrationTest {
    private static int passed;

    private static final class Fixture {
        AudioFocusCoordinator.Result result = AudioFocusCoordinator.Result.GRANTED;
        boolean failRequest;
        boolean alreadyUnregistered;
        boolean failRegister;
        boolean failUnregister;
        boolean failAbandon;
        boolean releaseFocus = true;
        int registers;
        int unregisters;
        int abandons;
        final List<String> operations = new ArrayList<>();
        final List<AudioFocusCoordinator.Diagnostic> diagnostics = new ArrayList<>();
        final NoisyAudioFocusRegistration registration = new NoisyAudioFocusRegistration(
                new AudioFocusCoordinator.Registration() {
                    @Override
                    public AudioFocusCoordinator.Result request() {
                        operations.add("request");
                        if (failRequest) throw new SecurityException("https://private/media?token=SECRET");
                        return result;
                    }

                    @Override
                    public boolean abandon() {
                        operations.add("abandon");
                        abandons++;
                        if (failAbandon) throw new IllegalStateException("focus cleanup failed: SECRET");
                        return releaseFocus;
                    }
                }, new NoisyAudioFocusRegistration.Receiver() {
                    @Override
                    public void register() {
                        operations.add("register");
                        registers++;
                        if (failRegister) throw new IllegalStateException("register failed: SECRET");
                    }

                    @Override
                    public void unregister() {
                        operations.add("unregister");
                        unregisters++;
                        if (alreadyUnregistered) throw new IllegalArgumentException("receiver SECRET");
                        if (failUnregister) throw new IllegalStateException("unregister failed: SECRET");
                    }
                });

        Fixture() {
            registration.setDiagnostics((category, outcome, error) -> diagnostics.add(
                    new AudioFocusCoordinator.Diagnostic(17, category, outcome, error)));
        }

        String log() {
            StringBuilder log = new StringBuilder();
            for (AudioFocusCoordinator.Diagnostic diagnostic : diagnostics) {
                log.append(diagnostic.logLine()).append("\n");
            }
            return log.toString();
        }
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
        test("native OS denial has no exception or receiver registration", () -> {
            Fixture f = new Fixture();
            f.result = AudioFocusCoordinator.Result.FAILED;
            equal(AudioFocusCoordinator.Result.FAILED, f.registration.request());
            equal("category=native_request requestId=17 result=failed\n", f.log());
        });
        test("native request exceptions preserve origin without private message", () -> {
            Fixture f = new Fixture();
            f.failRequest = true;
            try {
                f.registration.request();
                throw new AssertionError("Expected request to throw");
            } catch (SecurityException expected) {
                equal("category=native_request requestId=17 result=error exceptionClass=java.lang.SecurityException\n",
                        f.log());
                equal(0, f.registers);
            }
        });
        test("receiver registration failure cannot be mistaken for native denial", () -> {
            Fixture f = new Fixture();
            f.failRegister = true;
            AudioFocusCoordinator owner = new AudioFocusCoordinator(
                    listener -> f.registration, (id, change) -> {}, f.diagnostics::add);
            equal(AudioFocusCoordinator.Result.FAILED, owner.request(23));
            equal(true, f.log().contains("category=native_request requestId=23 result=granted\n"));
            equal(true, f.log().contains("category=noisy_register requestId=23 result=error exceptionClass=java.lang.IllegalStateException\n"));
            equal(true, f.log().contains("category=native_abandon requestId=23 result=success\n"));
            equal(false, f.log().contains("SECRET"));
            equal(1, f.abandons);
            equal(1, f.unregisters);
        });
        test("receiver and native cleanup errors remain separately visible", () -> {
            Fixture f = new Fixture();
            f.registration.request();
            f.failUnregister = true;
            f.failAbandon = true;
            equal(false, f.registration.abandon());
            equal(true, f.log().contains("category=noisy_unregister requestId=17 result=error exceptionClass=java.lang.IllegalStateException\n"));
            equal(true, f.log().contains("category=native_abandon requestId=17 result=error exceptionClass=java.lang.IllegalStateException\n"));
            equal(false, f.log().contains("SECRET"));
        });
        test("native abandon rejection differs from an exception", () -> {
            Fixture f = new Fixture();
            f.registration.request();
            f.releaseFocus = false;
            equal(false, f.registration.abandon());
            equal("category=native_abandon requestId=17 result=failed",
                    f.diagnostics.get(f.diagnostics.size() - 1).logLine());
        });
        test("already absent receiver is diagnosed and does not block cleanup", () -> {
            Fixture f = new Fixture();
            f.registration.request();
            f.alreadyUnregistered = true;
            equal(true, f.registration.abandon());
            equal(true, f.log().contains("category=noisy_unregister requestId=17 result=success exceptionClass=java.lang.IllegalArgumentException\n"));
            equal(true, f.registration.abandon());
            equal(1, f.unregisters);
            equal(1, f.abandons);
            equal(false, f.log().contains("SECRET"));
        });
        System.out.println(passed + " noisy receiver lifecycle JVM tests passed");
    }
}
