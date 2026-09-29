enum RepeatMode { off, all, one }

/// Device-local playback preferences, without queue or account state.
final class PlaybackSettings {
  const PlaybackSettings({
    this.volume,
    this.lastPositiveVolume = 100,
    this.shuffle = false,
    this.repeatMode = RepeatMode.off,
  });

  /// Null leaves the native player's default volume untouched.
  final double? volume;
  final double lastPositiveVolume;
  final bool shuffle;
  final RepeatMode repeatMode;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'volume': volume,
    'lastPositiveVolume': lastPositiveVolume,
    'shuffle': shuffle,
    'repeatMode': repeatMode.name,
  };

  factory PlaybackSettings.fromJson(Map<String, dynamic> json) {
    // Unversioned records use the original schema; explicit unknown or invalid
    // versions are not interpreted as that schema.
    final version = json.containsKey('version') ? json['version'] : 1;
    if (version is! int || version != 1) {
      return const PlaybackSettings();
    }

    final volume = _volume(json['volume']);
    final storedLastPositive = _volume(json['lastPositiveVolume']);
    final lastPositive = volume != null && volume > 0
        ? volume
        : storedLastPositive != null && storedLastPositive > 0
        ? storedLastPositive
        : 100.0;
    final shuffle = json['shuffle'];
    final repeat = json['repeatMode'];
    return PlaybackSettings(
      volume: volume,
      lastPositiveVolume: lastPositive,
      shuffle: shuffle is bool ? shuffle : false,
      repeatMode: RepeatMode.values.firstWhere(
        (mode) => mode.name == repeat,
        orElse: () => RepeatMode.off,
      ),
    );
  }

  static double? _volume(dynamic value) {
    if (value is! num || !value.isFinite || value < 0 || value > 100) {
      return null;
    }
    return value.toDouble();
  }
}
