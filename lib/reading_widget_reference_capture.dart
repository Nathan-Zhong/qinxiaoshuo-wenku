import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reading_widget_reference.dart';
import 'reading_widget_snapshot.dart';

/// Renders one complete desktop face into PNG bytes. Native hosts only receive
/// pixels, so this is the single place where the paint is rasterized.
Future<Uint8List> renderReadingDesktopCard(
  ReadingWidgetSnapshot data,
  ReadingDesktopSize size, {
  Brightness brightness = Brightness.light,
  bool paintQuote = true,
  double pixelRatio = 3,
}) async {
  await warmReadingDesktopImages(data);
  final ratio = pixelRatio.isFinite && pixelRatio > 0 ? pixelRatio : 3.0;
  final painter = ReadingDesktopCardPainter(
    data: data,
    size: size,
    brightness: brightness,
    quoteText: data.design.name == 'quote' ? null : null,
    cover: readingDesktopCover(data.latestCompletion?.coverPath),
    paintQuote: paintQuote,
  );
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.scale(ratio);
  painter.paint(
    canvas,
    const Size(readingDesktopCardWidth, readingDesktopCardHeight),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (readingDesktopCardWidth * ratio).round(),
    (readingDesktopCardHeight * ratio).round(),
  );
  try {
    final value = await image.toByteData(format: ui.ImageByteFormat.png);
    if (value == null) {
      throw StateError('desktop card could not be encoded as PNG');
    }
    return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// The three files the channel expects under exactly `small`, `medium`,
/// `large`. The controller writes them to disk and forwards the paths.
Future<Map<String, Uint8List>> renderReadingDesktopCards(
  ReadingWidgetSnapshot data, {
  double pixelRatio = 3,
}) async {
  await warmReadingDesktopImages(data);
  final images = <String, Uint8List>{};
  for (final size in ReadingDesktopSize.values) {
    images[size.name] = await renderReadingDesktopCard(
      data,
      size,
      brightness: Brightness.light,
      pixelRatio: pixelRatio,
    );
  }
  return images;
}
