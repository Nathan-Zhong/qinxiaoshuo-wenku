import 'dart:convert';
import 'dart:ui' show Brightness, Color;

/// The five painted faces plus the untouched platform surface.
///
/// Ids are the contract shared with the three native widget hosts. Keep the
/// enum names stable: they are persisted as `skinId` and written into cards.
enum ReadingWidgetSkin {
  original('原色', '保留系统原有的纸张与夜色', false),
  seasons('四季', '月份换一套颜色，留住季节', false),
  archive('档案', '装订线、索引条和档案纸', false),
  night('夜航', '深夜底色与一点月光金', true),
  film('胶片', '黑色片基与齿孔', true),
  paper('纸页', '灰白纸页与一截胶带', false);

  const ReadingWidgetSkin(this.label, this.description, this.dark);

  final String label, description;
  final bool dark;

  /// Old releases used palette/theme names here. Unknown values must never
  /// break a saved card, so they fall back to the unskinned original.
  static ReadingWidgetSkin fromId(String? value) => switch (value) {
    'seasons' || 'season' => seasons,
    'archive' || 'shelf' || 'editorial' => archive,
    'night' || 'constellation' => night,
    'film' || 'signal' || 'score' => film,
    'paper' => paper,
    'original' || 'classic' || 'cream' => original,
    _ => original,
  };

  /// Tolerant reader for preference JSON written by older builds.
  static ReadingWidgetSkin fromJson(Object? value) {
    if (value is String) return fromId(value);
    if (value is Map) {
      return fromId(
        switch (value['skin'] ?? value['skinId'] ?? value['id']) {
          final String id => id,
          _ => null,
        },
      );
    }
    return original;
  }

  static ReadingWidgetSkin decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return original;
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return fromId(raw);
    }
  }

  Map<String, Object?> toJson() => {'version': 1, 'skin': name};

  String encode() => jsonEncode(toJson());

  Color backgroundFor(Brightness brightness) => switch (this) {
    original => brightness == Brightness.dark
        ? const Color(0xFF17191B)
        : const Color(0xFFF4F0E6),
    night => const Color(0xFF101419),
    film => const Color(0xFF10100F),
    paper => const Color(0xFFECECE5),
    seasons || archive => const Color(0xFFF4F0E6),
  };

  Color inkFor(Brightness brightness) => switch (this) {
    night || film => const Color(0xFFF6F1E6),
    original => brightness == Brightness.dark
        ? const Color(0xFFF2EFE6)
        : const Color(0xFF272C29),
    paper || seasons || archive => const Color(0xFF272C29),
  };

  Color mutedFor(Brightness brightness) => switch (this) {
    night => const Color(0xFF9AA3AD),
    film => const Color(0xFFA9A49A),
    original => brightness == Brightness.dark
        ? const Color(0xFFA9AAA4)
        : const Color(0xFF6F6A5E),
    paper => const Color(0xFF6F7A6F),
    seasons || archive => const Color(0xFF6F6A5E),
  };

  Color get accent => switch (this) {
    night || film => const Color(0xFFDCB65E),
    paper => const Color(0xFF606D5D),
    original || seasons || archive => const Color(0xFF4F8985),
  };

  /// Seasons uses the same four seasonal accents as the native host.
  Color accentFor(DateTime localDay) => this == seasons
      ? seasonalAccent(localDay.month)
      : accent;

  static Color seasonalAccent(int month) => switch (month) {
    >= 3 && <= 5 => const Color(0xFFAF7D8B),
    >= 6 && <= 8 => const Color(0xFF5786A2),
    >= 9 && <= 11 => const Color(0xFFB18842),
    _ => const Color(0xFF4F8985),
  };

  static String seasonalCharacter(int month) => switch (month) {
    >= 3 && <= 5 => '春',
    >= 6 && <= 8 => '夏',
    >= 9 && <= 11 => '秋',
    _ => '冬',
  };
}

/// Stored goals are whole minutes. Old or hand-edited values are clamped
/// rather than trusted, so the native renderer never divides by a wild number.
int readingDailyGoal(int? minutes) {
  if (minutes == null || minutes <= 0) return 0;
  return minutes < 1440 ? minutes : 1440;
}

/// The single sentence shown under the goal control and inside the focus face.
String readingGoalCaption(int minutes, int? verifiedTodaySeconds) {
  final goal = readingDailyGoal(minutes);
  if (goal == 0) return '按自己的节奏阅读';
  final seconds = verifiedTodaySeconds;
  if (seconds == null) return '每日目标 $goal 分钟';
  final read = _goalMinutes(seconds);
  if (seconds >= goal * 60) return '今日目标已完成 · 已读 $read 分钟';
  return '每日目标 $goal 分钟 · 今日已读 $read 分钟';
}

String _goalMinutes(int seconds) => seconds <= 0
    ? '0'
    : seconds < 60
    ? '不足 1'
    : '${seconds ~/ 60}';
