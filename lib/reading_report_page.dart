import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'reading_export_theme.dart';
import 'reading_report_options.dart';
import 'reading_report_range.dart';
import 'reading_statistics_analysis_view.dart';
import 'reading_statistics_data.dart';

/// The shareable reading report.
///
/// The page reuses [ReadingStatisticsData] for the selected interval, so the
/// numbers always match the statistics page. Layout choices are kept in
/// [ReadingReportOptions] and only affect how this page presents that data.
class ReadingReportPage extends StatefulWidget {
  const ReadingReportPage({
    super.key,
    required this.state,
    required this.repository,
    this.now,
    required this.initialRange,
  });

  final LibraryState state;
  final NovelRepository repository;
  final DateTime? now;
  final ReadingReportRange initialRange;

  @override
  State<ReadingReportPage> createState() => _ReadingReportPageState();
}

class _ReadingReportPageState extends State<ReadingReportPage> {
  late final DateTime _now = widget.now ?? DateTime.now();
  late ReadingReportRange _range = widget.initialRange;
  ReadingReportOptions _options = const ReadingReportOptions();
  late ReadingStatisticsData _data = _buildData();

  ReadingStatisticsData _buildData() => ReadingStatisticsData(
    state: widget.state,
    repository: widget.repository,
    now: _range.endAt(_now),
    snapshotAt: _now,
    period: _range.daysAt(_now),
  );

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final options = await ReadingReportOptions.load();
    if (!mounted) return;
    setState(() => _options = options);
  }

  void _update(ReadingReportOptions options) {
    setState(() => _options = options);
  }

  void _setPeriod(int period) {
    setState(() {
      _range = ReadingReportRange(period: period);
      _data = _buildData();
    });
  }

  Future<void> _pickCustomRange() async {
    final picked = await pickReadingReportRange(
      context,
      now: _now,
      range: _range,
    );
    if (!mounted || picked == null) return;
    setState(() {
      _range = ReadingReportRange(
        period: _range.period,
        from: picked.start,
        until: picked.end,
      );
      _data = _buildData();
    });
  }

  Future<void> _saveOptions() async {
    final next = _options.copyWith(
      period: _range.custom ? _options.period : _range.period,
      from: _range.from,
      until: _range.until,
      clearDates: !_range.custom,
    );
    await next.save();
    if (!mounted) return;
    setState(() => _options = next);
    showNovelFeedback(context, '阅读报告设置已保存');
  }

  Future<void> _share() async {
    final buffer = StringBuffer()
      ..writeln('《${_options.title}》')
      ..writeln(
        '${statisticsDate(_data.dates.first)} — '
        '${statisticsDate(_data.dates.last)}',
      )
      ..writeln(
        '总阅读 ${statisticsDuration(_data.totalSeconds)} · '
        '活跃 ${_data.activeDays} 天',
      )
      ..writeln(
        '连续阅读 ${_data.currentStreak} 天 · '
        '最长 ${_data.longestStreak} 天',
      );
    if (_options.note.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(_options.note.trim());
    }
    if (_options.signature) {
      buffer
        ..writeln()
        ..writeln('$readingExportBrandName · 阅读报告');
    }
    await LocalPlatform.shareText(buffer.toString());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ArchiveFeaturePage(
      title: '阅读报告',
      code: 'REPORT / READING',
      actions: [
        GlassIconButton(
          icon: Icons.ios_share_rounded,
          label: '分享阅读报告',
          onPressed: _share,
        ),
        GlassIconButton(
          icon: Icons.save_outlined,
          label: '保存报告设置',
          onPressed: _saveOptions,
        ),
      ],
      child: ListView(
        padding: featurePadding(context),
        children: [
          _header(colors),
          const SizedBox(height: 6),
          ArchiveSection(
            title: '统计区间',
            code: 'RANGE / PERIOD',
            subtitle: _range.custom ? '自定义日期' : '最近 ${_range.period} 天',
          ),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppControls.segments<int>(
                  context,
                  groupValue:
                      !_range.custom &&
                          const {7, 30, 90, 365}.contains(_range.period)
                      ? _range.period
                      : null,
                  children: {
                    for (final period in const [7, 30, 90, 365])
                      period: AppText('$period 天'),
                  },
                  onValueChanged: (value) {
                    if (value != null) _setPeriod(value);
                  },
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GlassTextButton(
                    compact: true,
                    onPressed: _pickCustomRange,
                    child: AppText(
                      _range.custom
                          ? '${statisticsDate(_range.from!)} — '
                                '${statisticsDate(_range.until!)}'
                          : '自定义日期',
                    ),
                  ),
                ),
              ],
            ),
          ),
          ArchiveSection(
            title: '版式',
            code: 'STYLE / TEMPLATE',
            subtitle: '报表的配色与字体气质',
          ),
          ContentPanel(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final template in ReadingReportTemplate.values)
                  GlassTextButton(
                    compact: true,
                    selected: _options.template == template,
                    onPressed: () =>
                        _update(_options.copyWith(template: template)),
                    child: AppText(template.label),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          ContentPanel(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final palette in ReadingReportPalette.values)
                  GlassTextButton(
                    compact: true,
                    selected: _options.palette == palette,
                    onPressed: () =>
                        _update(_options.copyWith(palette: palette)),
                    child: AppText(palette.label),
                  ),
              ],
            ),
          ),
          ArchiveSection(
            title: '内容',
            code: 'MODULE / CONTENT',
            subtitle: '选择报告里要出现的小节',
          ),
          ContentPanel(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final module in ReadingReportModule.values)
                  GlassTextButton(
                    compact: true,
                    selected: _options.modules.contains(module),
                    onPressed: () {
                      final modules = <ReadingReportModule>{
                        ..._options.modules,
                      };
                      if (!modules.remove(module)) modules.add(module);
                      _update(_options.copyWith(modules: modules));
                    },
                    child: AppText(module.label),
                  ),
              ],
            ),
          ),
          for (final module in _options.orderedModules)
            if (_options.modules.contains(module)) ...[
              ArchiveSection(
                title: module.label,
                code: 'REPORT / ${module.name.toUpperCase()}',
              ),
              ContentPanel(
                child:
                    module == ReadingReportModule.days &&
                        _options.modules.contains(ReadingReportModule.calendar)
                    ? _footprint()
                    : ReadingStatisticsAnalysisView(
                        data: _data,
                        module: module,
                      ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _footprint() {
    final colors = Theme.of(context).colorScheme;
    final entries = <(DateTime, int)>[
      for (var i = 0; i < _data.dates.length && i < _data.seconds.length; i++)
        if ((_data.seconds[i] ?? 0) > 0) (_data.dates[i], _data.seconds[i]!),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    if (entries.isEmpty) {
      return AppText(
        '这段时间还没有记录到阅读时长。',
        style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in entries.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                AppText(
                  statisticsDate(entry.$1),
                  style: const TextStyle(fontSize: 13),
                ),
                AppText(
                  statisticsDuration(entry.$2),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        if (entries.length > 6) ...[
          const SizedBox(height: 6),
          AppText(
            '还有 ${entries.length - 6} 个有记录的日子',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _header(ColorScheme colors) {
    final first = _data.dates.first;
    final last = _data.dates.last;
    return ContentPanel(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            _options.title,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
          if (_options.nickname.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            AppText(
              _options.nickname,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          AppText(
            '${statisticsDate(first)} — ${statisticsDate(last)} · '
            '${_data.period} 天',
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          if (_options.note.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            AppText(
              _options.note,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 26,
            runSpacing: 14,
            children: [
              _metric('总阅读', statisticsDuration(_data.totalSeconds), colors),
              _metric('活跃天数', '${_data.activeDays} 天', colors),
              _metric('平均每天', statisticsDuration(_data.averageSeconds), colors),
              _metric('当前连续', '${_data.currentStreak} 天', colors),
              _metric('最长连续', '${_data.longestStreak} 天', colors),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, ColorScheme colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      AppText(
        label,
        style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
      ),
      const SizedBox(height: 3),
      AppText(
        value,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ],
  );
}
