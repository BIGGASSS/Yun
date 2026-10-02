package app.yun.yun;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Engine-owned bridge; never holds an Activity or releases focus on its detach. */
public final class AndroidAudioFocusPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private AudioFocusCoordinator coordinator;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        Handler handler = new Handler(Looper.getMainLooper());
        Context context = binding.getApplicationContext();
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        channel = new MethodChannel(binding.getBinaryMessenger(), "yun/android_audio_focus");
        coordinator = new AudioFocusCoordinator(
                listener -> prepare(context, manager, handler, listener),
                (requestId, change) -> {
                    if (channel == null) return;
                    Map<String, Object> event = new HashMap<>();
                    event.put("requestId", requestId);
                    event.put("change", changeName(change));
                    channel.invokeMethod("focusChanged", event);
                });
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (coordinator == null) {
            result.error("audio_focus_unavailable", "Audio focus bridge is detached", null);
            return;
        }
        switch (call.method) {
            case "request":
                Object id = call.argument("requestId");
                if (!(id instanceof Number)) {
                    result.error("invalid_request", "requestId must be an integer", null);
                    return;
                }
                result.success(resultName(coordinator.request(((Number) id).longValue())));
                break;
            case "abandon":
                result.success(coordinator.abandon());
                break;
            default:
                result.notImplemented();
        }
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
        coordinator.dispose();
        coordinator = null;
    }

    private static String resultName(AudioFocusCoordinator.Result result) {
        switch (result) {
            case GRANTED: return "granted";
            case DELAYED: return "delayed";
            default: return "failed";
        }
    }

    private static String changeName(AudioFocusCoordinator.Change change) {
        switch (change) {
            case GAIN: return "gain";
            case TRANSIENT_LOSS: return "transientLoss";
            case NOISY: return "noisy";
            default: return "loss";
        }
    }

    @SuppressWarnings("deprecation")
    private static AudioFocusCoordinator.Registration prepare(
            Context context, AudioManager manager, Handler handler,
            AudioFocusCoordinator.Listener listener) {
        AudioManager.OnAudioFocusChangeListener nativeListener = focusChange -> {
            AudioFocusCoordinator.Change change;
            switch (focusChange) {
                case AudioManager.AUDIOFOCUS_GAIN:
                    change = AudioFocusCoordinator.Change.GAIN;
                    break;
                case AudioManager.AUDIOFOCUS_LOSS:
                    change = AudioFocusCoordinator.Change.LOSS;
                    break;
                case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                    // Yun pauses rather than ducking, on legacy Android too.
                    change = AudioFocusCoordinator.Change.TRANSIENT_LOSS;
                    break;
                default:
                    return;
            }
            // Always post, including legacy callbacks. Acquisition's tri-state
            // method reply precedes its events on this same platform thread.
            handler.post(() -> listener.onChange(change));
        };
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return withNoisyReceiver(context, handler, listener,
                    Api26.prepare(manager, handler, nativeListener));
        }
        return withNoisyReceiver(context, handler, listener, new AudioFocusCoordinator.Registration() {
            @Override
            public AudioFocusCoordinator.Result request() {
                int result = manager.requestAudioFocus(
                        nativeListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
                // API 24–25 cannot register for delayed gain. Never manufacture
                // a pending request from a legacy denial.
                return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
                        ? AudioFocusCoordinator.Result.GRANTED : AudioFocusCoordinator.Result.FAILED;
            }

            @Override
            public boolean abandon() {
                return manager.abandonAudioFocus(nativeListener) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
            }
        });
    }

    private static AudioFocusCoordinator.Registration withNoisyReceiver(
            Context context, Handler handler, AudioFocusCoordinator.Listener listener,
            AudioFocusCoordinator.Registration focus) {
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context ignored, Intent intent) {
                if (AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(intent.getAction())) {
                    // Like focus callbacks, route events retain this request's
                    // listener identity and are dropped after cancel/replace.
                    handler.post(() -> listener.onChange(AudioFocusCoordinator.Change.NOISY));
                }
            }
        };
        return new NoisyAudioFocusRegistration(focus, new NoisyAudioFocusRegistration.Receiver() {
            @Override
            public void register() {
                // This protected system-only action uses the documented Android
                // 14 exception: no RECEIVER_EXPORTED/NOT_EXPORTED flags. It also
                // works on API 24–32, without an Activity or extra dependency.
                context.registerReceiver(receiver,
                        new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), null, handler);
            }

            @Override
            public void unregister() {
                try {
                    context.unregisterReceiver(receiver);
                } catch (IllegalArgumentException alreadyUnregistered) {
                    // registerReceiver can fail before installing the receiver.
                    // That case has no remaining receiver resource to release.
                }
            }
        });
    }

    /** Isolates API 26 types from the legacy code path. */
    private static final class Api26 {
        static AudioFocusCoordinator.Registration prepare(
                AudioManager manager, Handler handler,
                AudioManager.OnAudioFocusChangeListener listener) {
            AudioFocusRequest request = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build())
                    .setAcceptsDelayedFocusGain(true)
                    .setWillPauseWhenDucked(true)
                    .setOnAudioFocusChangeListener(listener, handler)
                    .build();
            return new AudioFocusCoordinator.Registration() {
                @Override
                public AudioFocusCoordinator.Result request() {
                    switch (manager.requestAudioFocus(request)) {
                        case AudioManager.AUDIOFOCUS_REQUEST_GRANTED:
                            return AudioFocusCoordinator.Result.GRANTED;
                        case AudioManager.AUDIOFOCUS_REQUEST_DELAYED:
                            return AudioFocusCoordinator.Result.DELAYED;
                        default:
                            return AudioFocusCoordinator.Result.FAILED;
                    }
                }

                @Override
                public boolean abandon() {
                    return manager.abandonAudioFocusRequest(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
                }
            };
        }
    }
}
