import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_cover.dart';

import 'support/cover_fixture.dart';

/// Regression: on the discovery page a Legado book whose title wraps to
/// two lines (《突然转生为龙骑士的我目标就是推倒众多公主们》) overflowed
/// the carousel's exact-fit label area by ~0.5px, painting the debug
/// "BOTTOM OVERFLOWED" stripe and squeezing the author line. The label
/// area now carries a small rounded slack (archive_wave.dart, mirrored
/// in the skeleton in loading_ui.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two-line carousel title does not overflow the label area', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = (await tester.runAsync(coverFixtureBytes))!;
    final book = Novel(
      id: 970099,
      title: '突然转生为龙骑士的我目标就是推倒众多公主们',
      author: '测试作者',
      genre: '奇幻玄幻',
      summary: '',
      coverUrl: 'fixture://cover/970099',
      colors: const [Colors.grey, Colors.white],
    );
    LegacyCover.seedLocalBytes(book.id, bytes);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: Scaffold(
          body: Padding(
            // Same 24px page inset the discovery / shelf pages use, which
            // is what makes this title wrap to two lines.
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ArchiveFileCarousel(
              books: [book],
              reduceMotion: true,
              onOpen: _noopOpen,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('archive-file-carousel')),
      findsOneWidget,
    );
    // The two-line title itself is rendered (not ellipsised to one line
    // by an exception), and no RenderFlex overflow was reported.
    expect(find.text(book.title), findsWidgets);
    expect(tester.takeException(), isNull);
    // The label area height carries the +3 rounded slack at scale 1:
    // 16 + 17*1.35*2 + 12*1.4 = 78.7, +3 = 81.7, ceil = 82.
    expect(
      tester.getSize(find.byKey(const ValueKey('archive-shelf-open'))).height,
      82,
    );
  });
}

void _noopOpen(Novel book, Object heroTag) {}
