package app.yun.yun;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

/** Dependency-free JVM contract tests, run by android/test-audio-focus.sh. */
public final class AudioFocusCoordinatorTest {
    private static int passed;

    private static final class FakePlatform implements AudioFocusCoordinator.Platform {
        AudioFocusCoordinator.Result next = AudioFocusCoordinator.Result.GRANTED;
        boolean failPrepare;
        boolean failRequest;
        boolean failAbandon;
        boolean abandonResult = true;
        AudioFocusCoordinator.Change duringRequest;
        AudioFocusCoordinator.Change duringAbandon;
        final List<FakeRegistration> registrations = new ArrayList<>();

        @Override
        public AudioFocusCoordinator.Registration prepare(AudioFocusCoordinator.Listener listener) {
            if (failPrepare) throw new IllegalStateException("prepare failed");
            FakeRegistration registration = new FakeRegistration(this, listener);
            registrations.add(registration);
            return registration;
        }

        FakeRegistration latest() {
            return registrations.get(registrations.size() - 1);
        }
    }

    private static final class FakeRegistration implements AudioFocusCoordinator.Registration {
        final FakePlatform platform;
        final AudioFocusCoordinator.Listener listener;
        int requests;
        int abandons;

        FakeRegistration(FakePlatform platform, AudioFocusCoordinator.Listener listener) {
            this.platform = platform;
            this.listener = listener;
        }

        @Override
        public AudioFocusCoordinator.Result request() {
            requests++;
            if (platform.failRequest) throw new SecurityException("focus denied");
            if (platform.duringRequest != null) emit(platform.duringRequest);
            return platform.next;
        }

        @Override
        public boolean abandon() {
            abandons++;
            if (platform.duringAbandon != null) emit(platform.duringAbandon);
            if (platform.failAbandon) throw new IllegalStateException("abandon failed");
            return platform.abandonResult;
        }

        void emit(AudioFocusCoordinator.Change change) {
            listener.onChange(change);
        }
    }

    private static final class Fixture {
        final FakePlatform platform = new FakePlatform();
        final List<String> events = new ArrayList<>();
        final List<AudioFocusCoordinator.Diagnostic> diagnostics = new ArrayList<>();
        final AudioFocusCoordinator focus = new AudioFocusCoordinator(
                platform, (id, change) -> events.add(id + ":" + change), diagnostics::add);
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
        test("immediate grant registers once", () -> {
            Fixture f = new Fixture();
            equal(AudioFocusCoordinator.Result.GRANTED, f.focus.request(1));
            equal(1, f.platform.latest().requests);
            equal(0, f.events.size());
        });
        test("delayed gain retains exactly one pending registration", () -> {
            Fixture f = new Fixture();
            f.platform.next = AudioFocusCoordinator.Result.DELAYED;
            equal(AudioFocusCoordinator.Result.DELAYED, f.focus.request(1));
            equal(0, f.events.size());
            equal(0, f.platform.latest().abandons);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:GAIN"), f.events);
            equal(1, f.platform.latest().requests);
        });
        test("denial is failed, never delayed, and cannot gain later", () -> {
            Fixture f = new Fixture();
            f.platform.next = AudioFocusCoordinator.Result.FAILED;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(1));
            equal(1, f.platform.latest().abandons);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
        });
        test("cancel pending request drops queued gain and loss", () -> {
            Fixture f = new Fixture();
            f.platform.next = AudioFocusCoordinator.Result.DELAYED;
            f.focus.request(1);
            equal(true, f.focus.abandon());
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            f.platform.latest().emit(AudioFocusCoordinator.Change.LOSS);
            equal(0, f.events.size());
            equal(true, f.focus.abandon());
            equal(1, f.platform.latest().abandons);
        });
        test("replacement accepts only the new registration's events", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            FakeRegistration old = f.platform.latest();
            f.focus.request(2);
            old.emit(AudioFocusCoordinator.Change.GAIN);
            old.emit(AudioFocusCoordinator.Change.LOSS);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("2:GAIN"), f.events);
            equal(1, old.abandons);
        });
        test("native listener identity guards reused client IDs", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            FakeRegistration old = f.platform.latest();
            f.focus.request(1);
            old.emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:GAIN"), f.events);
        });
        test("transient loss preserves registration for gain", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.latest().emit(AudioFocusCoordinator.Change.TRANSIENT_LOSS);
            equal(0, f.platform.latest().abandons);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:TRANSIENT_LOSS", "1:GAIN"), f.events);
            equal(1, f.platform.latest().requests);
        });
        test("permanent loss retires registration and rejects later gain", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.latest().emit(AudioFocusCoordinator.Change.LOSS);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            f.platform.latest().emit(AudioFocusCoordinator.Change.LOSS);
            equal(Arrays.asList("1:LOSS"), f.events);
            equal(1, f.platform.latest().abandons);
            f.focus.abandon();
            equal(1, f.platform.latest().abandons);
        });
        test("a new explicit request works after permanent loss", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.latest().emit(AudioFocusCoordinator.Change.LOSS);
            equal(AudioFocusCoordinator.Result.GRANTED, f.focus.request(2));
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:LOSS", "2:GAIN"), f.events);
        });
        test("callback during abandon is already stale", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.duringAbandon = AudioFocusCoordinator.Change.GAIN;
            f.focus.abandon();
            equal(0, f.events.size());
        });
        test("request exception fails closed and releases callback", () -> {
            Fixture f = new Fixture();
            f.platform.failRequest = true;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(1));
            equal(1, f.platform.latest().abandons);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
        });
        test("prepare exception fails closed and next request can recover", () -> {
            Fixture f = new Fixture();
            f.platform.failPrepare = true;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(1));
            f.platform.failPrepare = false;
            equal(AudioFocusCoordinator.Result.GRANTED, f.focus.request(2));
        });
        test("abandon exception still invalidates pending callbacks", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.failAbandon = true;
            equal(false, f.focus.abandon());
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
        });
        test("failed abandonment reports failure without rearming old request", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.abandonResult = false;
            equal(false, f.focus.abandon());
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
        });
        test("failed cleanup is retried without reactivating its listener", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.abandonResult = false;
            equal(false, f.focus.abandon());
            equal(false, f.focus.abandon());
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
            f.platform.abandonResult = true;
            equal(true, f.focus.abandon());
            equal(3, f.platform.latest().abandons);
            equal(true, f.focus.abandon());
            equal(3, f.platform.latest().abandons);
        });
        test("replacement fails closed until previous native cleanup succeeds", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.abandonResult = false;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(2));
            equal(1, f.platform.registrations.size());
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
            f.platform.abandonResult = true;
            equal(AudioFocusCoordinator.Result.GRANTED, f.focus.request(3));
            equal(2, f.platform.registrations.size());
        });
        test("engine detach retries a previously failed abandonment", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.failAbandon = true;
            equal(false, f.focus.abandon());
            f.platform.failAbandon = false;
            f.focus.dispose();
            equal(2, f.platform.latest().abandons);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(0, f.events.size());
        });
        test("permanent-loss cleanup failure remains retired until retry succeeds", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            FakeRegistration old = f.platform.latest();
            f.platform.abandonResult = false;
            old.emit(AudioFocusCoordinator.Change.LOSS);
            old.emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:LOSS"), f.events);
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(2));
            equal(1, f.platform.registrations.size());
            f.platform.abandonResult = true;
            equal(AudioFocusCoordinator.Result.GRANTED, f.focus.request(3));
            old.emit(AudioFocusCoordinator.Change.GAIN);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:LOSS", "3:GAIN"), f.events);
        });
        test("denied request cleanup failure cannot leave a hidden focus owner", () -> {
            Fixture f = new Fixture();
            f.platform.next = AudioFocusCoordinator.Result.FAILED;
            f.platform.abandonResult = false;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(1));
            f.platform.next = AudioFocusCoordinator.Result.GRANTED;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(2));
            equal(1, f.platform.registrations.size());
            f.platform.abandonResult = true;
            equal(AudioFocusCoordinator.Result.GRANTED, f.focus.request(3));
            equal(2, f.platform.registrations.size());
        });
        test("loss during acquisition overrides immediate grant", () -> {
            Fixture f = new Fixture();
            f.platform.duringRequest = AudioFocusCoordinator.Change.LOSS;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(1));
            equal(Arrays.asList("1:LOSS"), f.events);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:LOSS"), f.events);
        });
        for (AudioFocusCoordinator.Result initial : Arrays.asList(
                AudioFocusCoordinator.Result.GRANTED, AudioFocusCoordinator.Result.DELAYED)) {
            test("unplug cancels " + initial + " registration and rejects late gain", () -> {
                Fixture f = new Fixture();
                f.platform.next = initial;
                f.focus.request(1);
                f.platform.latest().emit(AudioFocusCoordinator.Change.NOISY);
                f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
                f.platform.latest().emit(AudioFocusCoordinator.Change.NOISY);
                equal(Arrays.asList("1:NOISY"), f.events);
                equal(1, f.platform.latest().abandons);
            });
        }
        test("an old unplug event cannot cancel a replacement request", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            FakeRegistration old = f.platform.latest();
            f.focus.request(2);
            old.emit(AudioFocusCoordinator.Change.NOISY);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("2:GAIN"), f.events);
            equal(0, f.platform.latest().abandons);
        });
        test("unplug while transiently interrupted cancels automatic resume", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.latest().emit(AudioFocusCoordinator.Change.TRANSIENT_LOSS);
            f.platform.latest().emit(AudioFocusCoordinator.Change.NOISY);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:TRANSIENT_LOSS", "1:NOISY"), f.events);
        });
        test("unplug cleanup failure stays retired and cannot gain", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.platform.abandonResult = false;
            f.platform.latest().emit(AudioFocusCoordinator.Change.NOISY);
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(Arrays.asList("1:NOISY"), f.events);
            equal(false, f.focus.abandon());
            f.platform.abandonResult = true;
            equal(true, f.focus.abandon());
            equal(3, f.platform.latest().abandons);
        });
        test("engine detach cancels focus and rejects new acquisition", () -> {
            Fixture f = new Fixture();
            f.focus.request(1);
            f.focus.dispose();
            f.focus.dispose();
            f.platform.latest().emit(AudioFocusCoordinator.Change.GAIN);
            equal(1, f.platform.latest().abandons);
            equal(0, f.events.size());
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(2));
            equal(1, f.platform.registrations.size());
        });
        test("bridge prepare exception is distinct from an OS denial", () -> {
            Fixture failed = new Fixture();
            failed.platform.failPrepare = true;
            equal(AudioFocusCoordinator.Result.FAILED, failed.focus.request(41));
            equal("category=bridge_prepare requestId=41 result=error exceptionClass=java.lang.IllegalStateException",
                    failed.diagnostics.get(0).logLine());
            Fixture denied = new Fixture();
            denied.platform.next = AudioFocusCoordinator.Result.FAILED;
            equal(AudioFocusCoordinator.Result.FAILED, denied.focus.request(42));
            equal("category=request requestId=42 result=failed", denied.diagnostics.get(0).logLine());
        });
        test("cleanup reports old identity and blocks the new request explicitly", () -> {
            Fixture f = new Fixture();
            f.focus.request(41);
            f.platform.failAbandon = true;
            equal(AudioFocusCoordinator.Result.FAILED, f.focus.request(42));
            equal("category=abandon requestId=41 result=error exceptionClass=java.lang.IllegalStateException",
                    f.diagnostics.get(1).logLine());
            equal("category=request requestId=42 result=cleanup_blocked", f.diagnostics.get(2).logLine());
            equal(1, f.platform.registrations.size());
        });
        test("diagnostics contain only category identity result and exception class", () -> {
            RuntimeException error = new SecurityException("https://private/media?token=SECRET account=user");
            error.addSuppressed(new IllegalStateException("SECRET"));
            AudioFocusCoordinator.Diagnostic diagnostic = new AudioFocusCoordinator.Diagnostic(7,
                    AudioFocusCoordinator.Category.NATIVE_REQUEST, AudioFocusCoordinator.Outcome.ERROR, error);
            equal(Arrays.asList("requestId", "category", "result", "exceptionClass"),
                    new ArrayList<>(diagnostic.toMap().keySet()));
            equal("java.lang.SecurityException", diagnostic.toMap().get("exceptionClass"));
            equal(false, diagnostic.toMap().toString().contains("SECRET"));
            equal(false, diagnostic.logLine().contains("private"));
        });
        test("diagnostic failures cannot change focus ownership or results", () -> {
            FakePlatform platform = new FakePlatform();
            AudioFocusCoordinator owner = new AudioFocusCoordinator(platform, (id, change) -> {},
                    diagnostic -> { throw new IllegalStateException("diagnostic consumer failed"); });
            equal(AudioFocusCoordinator.Result.GRANTED, owner.request(1));
            equal(true, owner.abandon());
            equal(1, platform.latest().abandons);
        });
        System.out.println(passed + " audio focus JVM tests passed");
    }
}
