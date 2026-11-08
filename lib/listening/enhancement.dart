import 'package:flutter/services.dart';

/// Optional loudness boost applied to the listening audio session.
///
/// The preference is intentionally small and forgiving: it is stored as JSON
/// next to the other listening settings, so an older build may find missing or
/// malformed fields. Every bad value falls back to [defaultGain] instead of
/// making ordinary playback fail.
class ListeningEnhancementPreference {
  const ListeningEnhancementPreference({
    this.enabled = false,
    this.gain = defaultGain,
  });

  /// Quietest supported setting: the audio is passed through unchanged.
  static const double minGain = 0;

  /// Loudest supported setting, in decibels.
  static const double maxGain = 15;

  /// Default boost used when the user has never changed the setting.
  static const double defaultGain = 6;

  /// Whether the platform should apply [gain].
  final bool enabled;

  /// Requested boost in decibels, always within [minGain]..[maxGain].
  final double gain;

  /// Returns [value] limited to the supported decibel range.
  static double clampGain(double value) {
    if (!value.isFinite) return defaultGain;
    return value.clamp(minGain, maxGain).toDouble();
  }

  ListeningEnhancementPreference copyWith({bool? enabled, double? gain}) {
    return ListeningEnhancementPreference(
      enabled: enabled ?? this.enabled,
      gain: gain == null ? this.gain : clampGain(gain),
    );
  }

  /// Reads a value written by any earlier version.
  ///
  /// A missing map, a missing key, or a value of the wrong type keeps the
  /// default for that field; a damaged stored blob therefore degrades to the
  /// "enhancement off" state rather than breaking the settings screen.
  factory ListeningEnhancementPreference.fromJson(Object? value) {
    if (value is! Map) return const ListeningEnhancementPreference();
    final enabled = value['enabled'];
    return ListeningEnhancementPreference(
      enabled: enabled is bool ? enabled : false,
      gain: _readGain(value['gain']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'gain': gain,
  };

  static double _readGain(Object? value) {
    if (value is num) return clampGain(value.toDouble());
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      if (parsed != null) return clampGain(parsed);
    }
    return defaultGain;
  }

  @override
  bool operator ==(Object other) =>
      other is ListeningEnhancementPreference &&
      other.enabled == enabled &&
      other.gain == gain;

  @override
  int get hashCode => Object.hash(enabled, gain);

  @override
  String toString() =>
      'ListeningEnhancementPreference(enabled: $enabled, gain: $gain)';
}

/// Bridges [ListeningEnhancementPreference] to the optional native plugin.
///
/// The plugin is only present where the platform can apply a per-session gain
/// (currently Android). Everywhere else the channel is missing, which is a
/// normal state: calls are best effort and never interrupt playback.
class ListeningEnhancement {
  ListeningEnhancement({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('org.mewx.wenku8/listening_enhancement');

  final MethodChannel _channel;
  ListeningEnhancementPreference _preference =
      const ListeningEnhancementPreference();
  int? _audioSessionId;
  bool _disposed = false;
  bool _unavailable = false;

  /// Latest preference passed by the controller or the settings panel.
  ListeningEnhancementPreference get preference => _preference;

  /// Applies [value] and remembers the Android audio session it belongs to.
  ///
  /// The audio output calls this whenever a new session id becomes available
  /// and again with a null id when the player is torn down.
  Future<void> configure(
    ListeningEnhancementPreference value, {
    int? audioSessionId,
  }) async {
    if (_disposed) {
      return;
    }
    _preference = value;
    _audioSessionId = audioSessionId;
    await _send(value, audioSessionId: audioSessionId);
  }

  /// Applies [value] to the most recent audio session.
  Future<void> setPreference(ListeningEnhancementPreference value) async {
    if (_disposed) {
      return;
    }
    _preference = value;
    await _send(value, audioSessionId: _audioSessionId);
  }

  Future<void> _send(
    ListeningEnhancementPreference value, {
    required int? audioSessionId,
  }) async {
    if (_unavailable) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('configure', <String, Object?>{
        'enabled': value.enabled,
        'gain': value.gain,
        if (audioSessionId != null) 'audioSessionId': audioSessionId,
      });
    } on MissingPluginException {
      // The optional native gain plugin is absent on most platforms and in
      // builds that strip it out. Remember that and stop asking the channel.
      _unavailable = true;
    } on PlatformException {
      // A host-side failure (for example an invalidated audio session) must
      // not interrupt ordinary playback or the settings screen.
      return;
    } catch (_) {
      // Enhancement is strictly optional: no channel error may escape into
      // the playback controller or the widget tree.
      _unavailable = true;
    }
  }

  /// Releases the native effect; safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _audioSessionId = null;
    if (_unavailable) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('configure', <String, Object?>{
        'enabled': false,
        'gain': 0.0,
      });
    } on MissingPluginException {
      _unavailable = true;
    } on PlatformException {
      return;
    } catch (_) {
      _unavailable = true;
    }
  }
}
