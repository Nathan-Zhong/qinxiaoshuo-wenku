import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reading_widget_design.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_snapshot.dart';

/// The widget host stretches one PNG into every family. The logical canvas is
/// kept at the same 364 × 170 used by the in-app preview so that preview and
/// exported face can never drift apart.
const double readingDesktopCardWidth = 364;
const double readingDesktopCardHeight = 170;
const double readingDesktopCardAspect =
    readingDesktopCardWidth / readingDesktopCardHeight;

enum ReadingDesktopSize {
  small('小 2×2'),
  medium('中 4×2'),
  large('大 4×4');

  const ReadingDesktopSize(this.label);
  final String label;
}

/// Cache of decoded covers. The native host only receives PNG bytes, so the
/// Dart painter must be able to draw the same cover synchronously.
final Map<String, ui.Image> _desktopCovers = {};
final Set<String> _desktopCoversLoading = {};

Future<void> warmReadingDesktopImages(ReadingWidgetSnapshot data) async {
  if (!data.showBookDetails) return;
  final path = data.latestCompletion?.coverPath;
  if (path == null || path.isEmpty || _desktopCovers.containsKey(path)) return;
  if (!_desktopCoversLoading.add(path)) return;
  try {
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 320);
    final frame = await codec.getNextFrame();
    codec.dispose();
    _desktopCovers[path] = frame.image;
  } catch (_) {
    // A missing or corrupt cover only costs the thumbnail; the card remains.
  } finally {
    _desktopCoversLoading.remove(path);
  }
}

ui.Image? readingDesktopCover(String? path) =>
    path == null ? null : _desktopCovers[path];

/// A live preview of exactly the bytes handed to the Android widget.
class ReadingDesktopCard extends StatefulWidget {
  const ReadingDesktopCard({
    super.key,
    required this.data,
    required this.size,
    required this.brightness,
    this.quoteText,
    this.quoteSource = '',
    this.quoteCount = 0,
  });

  final ReadingWidgetSnapshot data;
  final ReadingDesktopSize size;
  final Brightness brightness;
  final String? quoteText;
  final String quoteSource;
  final int quoteCount;

  @override
  State<ReadingDesktopCard> createState() => _ReadingDesktopCardState();
}

class _ReadingDesktopCardState extends State<ReadingDesktopCard> {
  ui.Image? _cover;
  String? _coverPath;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant ReadingDesktopCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.latestCompletion?.coverPath != _coverPath ||
        widget.data.showBookDetails != oldWidget.data.showBookDetails) {
      _loadCover();
    }
  }

  Future<void> _loadCover() async {
    final path = widget.data.showBookDetails
        ? widget.data.latestCompletion?.coverPath
        : null;
    _coverPath = path;
    if (path == null || path.isEmpty) {
      if (mounted && _cover != null) setState(() => _cover = null);
      return;
    }
    await warmReadingDesktopImages(widget.data);
    if (!mounted || _coverPath != path) return;
    final image = readingDesktopCover(path);
    if (image != _cover) setState(() => _cover = image);
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: readingDesktopCardAspect,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: RepaintBoundary(
        child: CustomPaint(
          painter: ReadingDesktopCardPainter(
            data: widget.data,
            size: widget.size,
            brightness: widget.brightness,
            quoteText: widget.quoteText,
            quoteSource: widget.quoteSource,
            quoteCount: widget.quoteCount,
            cover: _cover,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

/// Draws one desktop face. [ReadingDesktopCard] and the PNG exporter both use
/// this painter, which is why the picture is never a screenshot of a phone.
class ReadingDesktopCardPainter extends CustomPainter {
  const ReadingDesktopCardPainter({
    required this.data,
    required this.size,
    required this.brightness,
    this.quoteText,
    this.quoteSource = '',
    this.quoteCount = 0,
    this.cover,
    this.paintQuote = true,
  });

  final ReadingWidgetSnapshot data;
  final ReadingDesktopSize size;
  final Brightness brightness;
  final String? quoteText;
  final String quoteSource;
  final int quoteCount;
  final ui.Image? cover;
  final bool paintQuote;

  ReadingWidgetSkin get _skin => data.skin;
  Color get _background => _skin.backgroundFor(brightness);
  Color get _ink => _skin.inkFor(brightness);
  Color get _muted => _skin.mutedFor(brightness);
  Color get _accent => _skin.accentFor(data.localDay);
  double get _padding => 18;
  double get _headingSize => size == ReadingDesktopSize.small ? 10 : 11;
  bool get _compact => size == ReadingDesktopSize.small;

  @override
  void paint(Canvas canvas, Size area) {
    canvas.drawRect(Offset.zero & area, Paint()..color = _background);
    _decorate(canvas, area);
    switch (data.design) {
      case ReadingWidgetDesign.classic:
        _classic(canvas, area);
      case ReadingWidgetDesign.focus:
        _focus(canvas, area);
      case ReadingWidgetDesign.week:
        _week(canvas, area);
      case ReadingWidgetDesign.calendar:
        _calendar(canvas, area);
      case ReadingWidgetDesign.memory:
        _memory(canvas, area);
      case ReadingWidgetDesign.quote:
        _quote(canvas, area);
    }
  }

  void _decorate(Canvas canvas, Size area) {
    final skin = _skin;
    switch (skin) {
      case ReadingWidgetSkin.original:
        return;
      case ReadingWidgetSkin.seasons:
        final colors = [
          const Color(0xFFAF7D8B),
          const Color(0xFF5786A2),
          const Color(0xFFB18842),
          const Color(0xFF4F8985),
        ];
        final width = area.width / colors.length;
        for (var index = 0; index < colors.length; index++) {
          canvas.drawRect(
            Rect.fromLTWH(index * width, area.height - 3, width, 3),
            Paint()..color = colors[index],
          );
        }
        _paint(
          canvas,
          ReadingWidgetSkin.seasonalCharacter(data.localDay.month),
          Offset(area.width - 112, area.height - 108),
          width: 104,
          fontSize: 104,
          color: _ink.withValues(alpha: .085),
          family: 'ReadingSerifDisplay',
          align: TextAlign.right,
        );
      case ReadingWidgetSkin.archive:
        canvas.drawRect(
          Rect.fromLTWH(0, 0, 4, area.height),
          Paint()..color = _accent,
        );
        for (var y = 12.0; y < area.height - 10; y += 16) {
          canvas.drawRect(
            Rect.fromLTWH(11, y, 7, 1.2),
            Paint()..color = _ink.withValues(alpha: .28),
          );
        }
      case ReadingWidgetSkin.night:
        canvas.drawCircle(
          Offset(area.width - 28, 27),
          16,
          Paint()..color = _accent.withValues(alpha: .10),
        );
        canvas.drawCircle(
          Offset(area.width - 28, 27),
          8,
          Paint()..color = _accent.withValues(alpha: .85),
        );
        final base = area.height;
        for (var index = 0; index < 9; index++) {
          final width = 16.0 + (index % 3) * 8;
          final height = 12.0 + (index % 4) * 6;
          final left = area.width - 8 - (index + 1) * 20.0;
          canvas.drawRect(
            Rect.fromLTWH(left, base - height, width, height),
            Paint()..color = _ink.withValues(alpha: .12),
          );
        }
      case ReadingWidgetSkin.film:
        final paint = Paint()..color = _ink.withValues(alpha: .26);
        for (var x = 12.0; x < area.width - 8; x += 22) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, 6, 7, 8),
              const Radius.circular(1.5),
            ),
            paint,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, area.height - 14, 7, 8),
              const Radius.circular(1.5),
            ),
            paint,
          );
        }
      case ReadingWidgetSkin.paper:
        canvas.save();
        canvas.translate(area.width - 54, 12);
        canvas.rotate(-.26);
        canvas.drawRect(
          const Rect.fromLTWH(-34, -9, 68, 18),
          Paint()..color = const Color(0xFFD8CDB4).withValues(alpha: .82),
        );
        canvas.restore();
    }
  }

  void _classic(Canvas canvas, Size area) {
    final pad = _padding;
    final show = data.showBookDetails;
    final title = show
        ? data.currentBook?.title ??
              data.latestCompletion?.title ??
              '轻小说文库'
        : '轻小说文库';
    final detail = show
        ? data.currentBook?.chapter ??
              data.latestCompletion?.author ??
              '阅读档案'
        : '阅读档案';
    _paint(
      canvas,
      '轻小说文库 / READING',
      Offset(pad, 14),
      width: area.width - pad * 2 - 100,
      fontSize: 9,
      color: _muted,
    );
    _paint(
      canvas,
      title,
      Offset(pad, 36),
      width: area.width - pad * 2 - 116,
      fontSize: _compact ? 19 : 23,
      weight: FontWeight.w600,
      color: _ink,
      maxLines: 2,
      lineHeight: 1.18,
    );
    _paint(
      canvas,
      detail,
      Offset(pad, 96),
      width: area.width - pad * 2 - 116,
      fontSize: 10,
      color: _muted,
    );

    final right = area.width - pad;
    _paint(
      canvas,
      '今日',
      Offset(right - 96, 24),
      width: 96,
      fontSize: 9,
      color: _muted,
      align: TextAlign.right,
    );
    _paint(
      canvas,
      widgetMinutes(data.verifiedTodaySeconds),
      Offset(right - 110, 38),
      width: 110,
      fontSize: _compact ? 38 : 46,
      weight: FontWeight.w700,
      color: _accent,
      family: 'ReadingDisplay',
      align: TextAlign.right,
    );
    _paint(
      canvas,
      '分钟',
      Offset(right - 96, 86),
      width: 96,
      fontSize: 9,
      color: _muted,
      align: TextAlign.right,
    );

    canvas.drawLine(
      Offset(pad, area.height - 36),
      Offset(area.width - pad, area.height - 36),
      Paint()
        ..color = _ink.withValues(alpha: .12)
        ..strokeWidth = .8,
    );
    final streak = data.qualifiedStreakDays ?? 0;
    _paint(
      canvas,
      '累计 ${widgetMinutes(data.verifiedTotalSeconds)} 分钟 · 连续 $streak 天',
      Offset(pad, area.height - 27),
      width: area.width - pad * 2 - 74,
      fontSize: 9,
      color: _muted,
    );
    _paint(
      canvas,
      '本周 ${widgetMinutes(data.weekSeconds)} 分钟',
      Offset(area.width - pad - 110, area.height - 27),
      width: 110,
      fontSize: 9,
      color: _muted,
      align: TextAlign.right,
    );
  }

  void _focus(Canvas canvas, Size area) {
    final pad = _padding;
    final day = data.localDay;
    final stamp =
        '${day.month.toString().padLeft(2, '0')}.'
        '${day.day.toString().padLeft(2, '0')} / 阅读';
    _paint(
      canvas,
      stamp,
      Offset(pad, 16),
      width: area.width - pad * 2,
      fontSize: _headingSize,
      color: _muted,
    );
    final streak = data.qualifiedStreakDays ?? 0;
    if (streak > 0) {
      _paint(
        canvas,
        '连续 $streak 天',
        Offset(area.width - pad - 110, 16),
        width: 110,
        fontSize: 10,
        color: _muted,
        align: TextAlign.right,
      );
    }
    _paint(
      canvas,
      widgetMinutes(data.verifiedTodaySeconds),
      Offset(pad - 2, 34),
      width: area.width - pad * 2,
      fontSize: _compact ? 54 : 62,
      weight: FontWeight.w700,
      color: _accent,
      family: 'ReadingDisplay',
      lineHeight: 1.05,
    );
    _paint(
      canvas,
      data.verifiedTodaySeconds == null ? '未记录' : '分钟',
      Offset(pad, 108),
      width: 100,
      fontSize: 11,
      color: _muted,
    );

    final goal = data.dailyGoalMinutes;
    if (goal > 0) {
      final seconds = data.verifiedTodaySeconds;
      final ratio = seconds == null
          ? 0.0
          : (seconds / (goal * 60)).clamp(0.0, 1.0).toDouble();
      final track = RRect.fromRectAndRadius(
        Rect.fromLTWH(pad, area.height - 36, area.width - pad * 2, 4),
        const Radius.circular(2),
      );
      canvas.drawRRect(track, Paint()..color = _ink.withValues(alpha: .12));
      if (ratio > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              pad,
              area.height - 36,
              (area.width - pad * 2) * ratio,
              4,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = _accent,
        );
      }
      _paint(
        canvas,
        readingGoalCaption(goal, seconds),
        Offset(pad, area.height - 26),
        width: area.width - pad * 2,
        fontSize: 9.5,
        color: _muted,
      );
    }
  }

  void _week(Canvas canvas, Size area) {
    final pad = _padding;
    _paint(
      canvas,
      '七日节律 / 7 DAYS',
      Offset(pad, 16),
      width: area.width - pad * 2 - 100,
      fontSize: _headingSize,
      color: _muted,
    );
    _paint(
      canvas,
      '${widgetMinutes(data.weekSeconds)} 分钟',
      Offset(area.width - pad - 130, 15),
      width: 130,
      fontSize: _compact ? 16 : 18,
      weight: FontWeight.w700,
      color: _ink,
      family: 'ReadingDisplay',
      align: TextAlign.right,
    );

    final top = 56.0;
    final baseline = area.height - 28;
    final maximum = math.max(
      300,
      data.week.fold<int>(
        0,
        (value, day) => math.max(value, day.verifiedSeconds ?? 0),
      ),
    );
    final step = (area.width - pad * 2) / 7;
    for (var index = 0; index < data.week.length; index++) {
      final day = data.week[index];
      final center = pad + step * index + step / 2;
      final half = step * .23;
      final seconds = day.verifiedSeconds;
      final paint = Paint()
        ..color = index == 6
            ? _accent
            : _accent.withValues(alpha: .55)
        ..style = seconds == null ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = 1;
      final height = seconds == null
          ? 3.0
          : math.max(2.0, (baseline - top - 8) * seconds / maximum);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(center - half, baseline - height, center + half, baseline),
          const Radius.circular(2),
        ),
        paint,
      );
      _paint(
        canvas,
        day.date.day.toString().padLeft(2, '0'),
        Offset(center - 12, area.height - 22),
        width: 24,
        fontSize: 8.5,
        color: _muted,
        align: TextAlign.center,
      );
    }
  }

  void _calendar(Canvas canvas, Size area) {
    final pad = _padding;
    final weeks = _compact ? 10 : size == ReadingDesktopSize.medium ? 14 : 18;
    final day = data.localDay;
    _paint(
      canvas,
      '阅读日历',
      Offset(pad, 15),
      width: area.width - pad * 2,
      fontSize: _headingSize,
      color: _muted,
    );
    _paint(
      canvas,
      '${day.year} / ${day.month.toString().padLeft(2, '0')}',
      Offset(pad, 34),
      width: area.width - pad * 2,
      fontSize: 26,
      weight: FontWeight.w700,
      color: _ink,
      family: 'ReadingDisplay',
    );

    final window = data.heatmap.window(weeks);
    final known = window.any((item) => item.verifiedSeconds != null);
    _paint(
      canvas,
      known ? '近 $weeks 周' : '尚未记录',
      Offset(area.width - pad - 100, 40),
      width: 100,
      fontSize: 9.5,
      color: _muted,
      align: TextAlign.right,
    );
    if (!known) return;

    final gap = 3.0;
    final left = pad;
    final top = 80.0;
    final usableWidth = area.width - pad * 2;
    final usableHeight = area.height - top - 16;
    final cell = math.min(
      (usableWidth - gap * (weeks - 1)) / weeks,
      (usableHeight - gap * 6) / 7,
    );
    for (var column = 0; column < weeks; column++) {
      for (var row = 0; row < 7; row++) {
        final index = column * 7 + row;
        if (index >= window.length) break;
        final level = readingWidgetHeatLevel(
          window[index].verifiedSeconds,
        );
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            left + column * (cell + gap),
            top + row * (cell + gap),
            cell,
            cell,
          ),
          const Radius.circular(1.5),
        );
        if (level == null) {
          canvas.drawRRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = .6
              ..color = _ink.withValues(alpha: .10),
          );
        } else if (level == 0) {
          canvas.drawRRect(
            rect,
            Paint()..color = _ink.withValues(alpha: .06),
          );
        } else {
          canvas.drawRRect(
            rect,
            Paint()
              ..color = _accent.withValues(
                alpha: const [.28, .48, .72, 1.0][level - 1],
              ),
          );
        }
      }
    }
  }

  void _memory(Canvas canvas, Size area) {
    final pad = _padding;
    final show = data.showBookDetails;
    final completion = data.latestCompletion;
    final title = show
        ? data.currentBook?.title ?? completion?.title ?? ''
        : '';
    final hasMoment = title.trim().isNotEmpty;
    final coverPath = show ? completion?.coverPath : null;
    final image = readingDesktopCover(coverPath);
    final coverWidth = image == null ? 0.0 : 66.0;
    final textWidth = area.width - pad * 2 - coverWidth - (coverWidth > 0 ? 12 : 0);

    _paint(
      canvas,
      hasMoment ? '书页留念' : '下一段故事',
      Offset(pad, 15),
      width: area.width - pad * 2,
      fontSize: _headingSize,
      color: _muted,
    );

    if (hasMoment) {
      final titleHeight = _paint(
        canvas,
        title,
        Offset(pad, 38),
        width: textWidth,
        fontSize: _compact ? 21 : 24,
        weight: FontWeight.w600,
        color: _ink,
        maxLines: 2,
        lineHeight: 1.2,
      );
      if (show && (completion?.author ?? '').trim().isNotEmpty) {
        _paint(
          canvas,
          completion!.author!,
          Offset(pad, 46 + titleHeight),
          width: textWidth,
          fontSize: 10,
          color: _muted,
        );
      }
      final footer = completion == null
          ? '正在读'
          : '${completion.completedAt.month}.${completion.completedAt.day} '
                '${completion.finished ? '读完' : '读到这里'}';
      _paint(
        canvas,
        footer,
        Offset(pad, area.height - 27),
        width: textWidth,
        fontSize: 9,
        color: _muted,
      );
      if (image != null) {
        final destination = Rect.fromLTWH(
          area.width - pad - coverWidth,
          (area.height - 94) / 2,
          coverWidth,
          94,
        );
        canvas.save();
        canvas.clipRRect(
          RRect.fromRectAndRadius(destination, const Radius.circular(3)),
        );
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          destination,
          Paint()..filterQuality = FilterQuality.medium,
        );
        canvas.restore();
        canvas.drawRRect(
          RRect.fromRectAndRadius(destination, const Radius.circular(3)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = .8
            ..color = _ink.withValues(alpha: .18),
        );
      }
    } else {
      _paint(
        canvas,
        '从这一页\n开始。',
        Offset(pad, 44),
        width: area.width - pad * 2,
        fontSize: _compact ? 23 : 26,
        weight: FontWeight.w600,
        color: _ink,
        maxLines: 2,
        lineHeight: 1.35,
      );
      _paint(
        canvas,
        '每日阅读会自动留在这里',
        Offset(pad, area.height - 27),
        width: area.width - pad * 2,
        fontSize: 9,
        color: _muted,
      );
    }
  }

  void _quote(Canvas canvas, Size area) {
    final pad = _padding;
    final body = (quoteText ?? '').trim();
    if (!paintQuote) {
      _paint(
        canvas,
        '摘录卡 / QUOTE',
        Offset(pad, 16),
        width: area.width - pad * 2,
        fontSize: _headingSize,
        color: _muted,
      );
      _paint(
        canvas,
        '“',
        Offset(pad - 2, 34),
        width: 80,
        fontSize: 64,
        color: _accent.withValues(alpha: .30),
        family: 'ReadingSerifDisplay',
      );
      return;
    }
    _paint(
      canvas,
      '“',
      Offset(pad - 2, 2),
      width: 70,
      fontSize: 58,
      color: _accent.withValues(alpha: .32),
      family: 'ReadingSerifDisplay',
    );
    _paint(
      canvas,
      body.isEmpty ? '在阅读中留下喜欢的句子' : body,
      Offset(pad, 46),
      width: area.width - pad * 2,
      fontSize: _compact ? 12.5 : 14,
      color: _ink,
      maxLines: 4,
      lineHeight: 1.5,
      height: 1.5,
    );
    _paint(
      canvas,
      quoteSource.trim().isEmpty ? '轻小说文库' : '— ${quoteSource.trim()}',
      Offset(pad, area.height - 26),
      width: area.width - pad * 2 - 70,
      fontSize: 9.5,
      color: _muted,
    );
    if (quoteCount > 0) {
      _paint(
        canvas,
        '$quoteCount 条摘录',
        Offset(area.width - pad - 80, area.height - 26),
        width: 80,
        fontSize: 9,
        color: _muted,
        align: TextAlign.right,
      );
    }
  }

  /// Lays out one run of text and returns the painted height. A single
  /// ellipsized line is the default; cards never grow past their frame.
  double _paint(
    Canvas canvas,
    String text,
    Offset at, {
    required double width,
    double fontSize = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    String? family,
    TextAlign align = TextAlign.left,
    int maxLines = 1,
    double lineHeight = 1.25,
    double? height,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          color: color,
          fontFamily: family,
          height: height ?? lineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1.0, width));
    painter.paint(canvas, at);
    final painted = painter.height;
    painter.dispose();
    return painted;
  }

  @override
  bool shouldRepaint(covariant ReadingDesktopCardPainter oldDelegate) =>
      oldDelegate.data != data ||
      oldDelegate.size != size ||
      oldDelegate.brightness != brightness ||
      oldDelegate.quoteText != quoteText ||
      oldDelegate.quoteSource != quoteSource ||
      oldDelegate.quoteCount != quoteCount ||
      oldDelegate.cover != cover ||
      oldDelegate.paintQuote != paintQuote;
}
