import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import 'book_import_limits.dart';
import 'local_book_archive.dart';

/// One book produced by [PortableBookPreparer.prepare].
///
/// A successful entry has a [path]; a failed entry has an [error] instead.
/// ZIP batches therefore surface per-file problems without failing the whole
/// import.
typedef PreparedBookDocument = ({String name, String? path, String? error});

/// Decodes archive entry names that were written with a legacy charset.
typedef BookNameDecoder = Future<List<String>> Function(List<String> names);

/// Hands one staged file to the platform book importer.
typedef BookConverter =
    Future<List<PreparedBookDocument>> Function(String name, String path);

/// Rebuilds a MOBI/AZW/AZW3/PRC file as EPUB.
typedef KindleExtractor = Future<int> Function(String source, String output);

/// Extracts the text layer of a PDF.
typedef PdfExtractor =
    Future<void> Function(String name, String source, String output);

/// Prepares non-TXT/EPUB imports for the portable reader.
///
/// The platform layer still owns the actual document conversion; this class
/// owns the parts that must behave the same on every platform:
///
/// * turn a ZIP of books into individual staged files;
/// * rebuild Kindle files as EPUB before conversion;
/// * extract PDF text where the platform supports it;
/// * keep the working directory prunable after each import.
///
/// All entries are best effort. A damaged entry becomes an error record while
/// its siblings continue, which keeps a single bad ZIP member from losing a
/// whole batch.
class PortableBookPreparer {
  PortableBookPreparer({
    required this.directory,
    required this.textCodecToken,
    required BookNameDecoder decodeNames,
    required BookConverter convert,
    required KindleExtractor extractKindle,
    PdfExtractor? extractPdf,
  }) : _decodeNames = decodeNames,
       _convert = convert,
       _extractKindle = extractKindle,
       _extractPdf = extractPdf;

  /// Scratch directory owned by the importer. Every prepared file is created
  /// below this path so [releasePaths] can delete it safely.
  final Directory directory;

  /// Root isolate token supplied by the host.
  ///
  /// The Dart side currently leaves TXT charset detection to the platform
  /// converter. The token stays on this object so the same contract can move
  /// decoding into a background isolate later without changing the caller. It
  /// is kept as [Object] so this module does not depend on a specific Flutter
  /// isolate API version.
  final Object? textCodecToken;

  final BookNameDecoder _decodeNames;
  final BookConverter _convert;
  final KindleExtractor _extractKindle;
  final PdfExtractor? _extractPdf;
  int _sequence = 0;

  static const int _maxExtractedBytes = 1024 * 1024 * 1024;
  static const Set<String> _portableExtensions = {
    'txt',
    'epub',
    'html',
    'htm',
    'xhtml',
    'fb2',
    'docx',
    'rtf',
    'md',
    'markdown',
    'mobi',
    'azw',
    'azw3',
    'prc',
    'pdf',
  };
  static const Set<String> _kindleExtensions = {
    'mobi',
    'azw',
    'azw3',
    'prc',
  };

  /// Removes staged files from an earlier app run.
  ///
  /// Cleanup is deliberately best effort: a locked file must not stop the
  /// importer from starting, because the new run gets its own directory.
  static Future<void> clearPreviousRuns(Directory directory) async {
    try {
      await directory.create(recursive: true);
      await for (final entity in directory.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      return;
    }
  }

  /// Prepares one picked file.
  ///
  /// [name] is the user-visible file name (its extension decides the path),
  /// while [path] is the staged file chosen by the host.
  Future<List<PreparedBookDocument>> prepare(String name, String path) async {
    final displayName = name.trim().isEmpty ? '未命名书籍' : name.trim();
    final source = File(path);
    var exists = false;
    try {
      exists = await source.exists();
    } on FileSystemException {
      exists = false;
    }
    if (path.trim().isEmpty || !exists) {
      return [_error(displayName, '找不到要导入的文件')];
    }
    final run = await _createRunDirectory();
    if (run == null) {
      return [_error(displayName, '无法创建临时目录，请检查存储空间')];
    }
    try {
      if (_extensionOf(displayName) == 'zip') {
        return await _prepareArchive(displayName, source, run);
      }
      return await _convertPath(displayName, source.path, run.path);
    } catch (error) {
      return [_error(displayName, _describe(error))];
    }
  }

  /// Deletes only files below [directory]; paths owned by the platform are
  /// handled by its own release call.
  Future<void> releasePaths(Iterable<String> paths) async {
    final root = directory.absolute.path;
    for (final path in paths.toSet()) {
      final target = File(path).absolute.path;
      if (!_isInside(root, target)) {
        continue;
      }
      try {
        final type = await FileSystemEntity.type(target, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          continue;
        }
        final entity = type == FileSystemEntityType.directory
            ? Directory(target)
            : File(target);
        await entity.delete(recursive: true);
        await _pruneEmptyParents(root, Directory(_parentOf(target)));
      } on FileSystemException {
        continue;
      }
    }
  }

  Future<List<PreparedBookDocument>> _prepareArchive(
    String name,
    File source,
    Directory run,
  ) async {
    final length = await source.length();
    if (length > maxLocalArchiveBytes) {
      return [_error(name, localBookSizeMessage(name))];
    }
    final archive = _decodeArchive(await source.readAsBytes());
    if (archive == null) {
      return [_error(name, '无法读取压缩包：文件已损坏或格式不受支持')];
    }
    final entries = <ArchiveFile>[
      for (final file in archive)
        if (!file.name.endsWith('/') &&
            _portableExtensions.contains(_extensionOf(file.name)))
          file,
    ];
    if (entries.isEmpty) {
      return [_error(name, '压缩包里没有可导入的书籍')];
    }
    final decoded = await _decodeNamesSafely([
      for (final entry in entries) entry.name,
    ]);
    final results = <PreparedBookDocument>[];
    var total = 0;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final extension = _extensionOf(entry.name);
      final decodedName = index < decoded.length ? decoded[index] : entry.name;
      final displayName = _bookName(
        decodedName,
        extension,
        fallback: 'book-${index + 1}',
      );
      if (entry.size < 0 || entry.size > localBookByteLimit(displayName)) {
        results.add(_error(displayName, localBookSizeMessage(displayName)));
        continue;
      }
      final bytes = _entryBytes(entry);
      if (bytes == null) {
        results.add(_error(displayName, '无法读取压缩包中的这个文件'));
        continue;
      }
      if (bytes.length > localBookByteLimit(displayName)) {
        results.add(_error(displayName, localBookSizeMessage(displayName)));
        continue;
      }
      total += bytes.length;
      if (total > _maxExtractedBytes) {
        results.add(_error(displayName, '压缩包展开后超过 1 GiB，未继续导入'));
        break;
      }
      try {
        final staged = await _stage(run, index, displayName, bytes);
        results.addAll(
          await _convertPath(displayName, staged.path, staged.folder),
        );
      } catch (error) {
        results.add(_error(displayName, _describe(error)));
      }
    }
    return results;
  }

  Future<List<PreparedBookDocument>> _convertPath(
    String name,
    String source,
    String workspace,
  ) async {
    final extension = _extensionOf(name).isEmpty
        ? _extensionOf(source)
        : _extensionOf(name);
    try {
      if (_kindleExtensions.contains(extension)) {
        final base = _safeName(_withoutExtension(name), fallback: 'book');
        final output = _child(workspace, '$base.epub');
        final code = await _extractKindle(source, output);
        if (code != 0) {
          return [_error(name, '无法解析 Kindle 文件（错误代码 $code）')];
        }
        return await _convertOrFail('$base.epub', output);
      }
      if (extension == 'pdf') {
        final extractPdf = _extractPdf;
        if (extractPdf == null) {
          return [_error(name, '当前平台暂不支持 PDF 导入')];
        }
        final base = _safeName(_withoutExtension(name), fallback: 'book');
        final output = _child(workspace, '$base.txt');
        await extractPdf(name, source, output);
        return await _convertOrFail('$base.txt', output);
      }
      return await _convertOrFail(name, source);
    } catch (error) {
      return [_error(name, _describe(error))];
    }
  }

  Future<List<PreparedBookDocument>> _convertOrFail(
    String name,
    String path,
  ) async {
    final values = await _convert(name, path);
    if (values.isEmpty) {
      return [_error(name, '未能识别该文件的内容')];
    }
    return values;
  }

  Future<({String folder, String path})> _stage(
    Directory run,
    int index,
    String name,
    Uint8List bytes,
  ) async {
    final folder = Directory(_child(run.path, 'entry-$index'));
    await folder.create(recursive: true);
    final file = File(_child(folder.path, _safeName(name, fallback: 'book')));
    await file.writeAsBytes(bytes, flush: true);
    return (folder: folder.path, path: file.path);
  }

  Future<Directory?> _createRunDirectory() async {
    final run = Directory(
      _child(
        directory.path,
        'run-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      ),
    );
    try {
      await run.create(recursive: true);
      return run;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _decodeNamesSafely(List<String> names) async {
    if (names.isEmpty) {
      return const [];
    }
    try {
      final decoded = await _decodeNames(names);
      return decoded.length == names.length ? decoded : names;
    } catch (_) {
      return names;
    }
  }

  Archive? _decodeArchive(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  Uint8List? _entryBytes(ArchiveFile entry) {
    try {
      return readLocalBookArchiveEntry(entry);
    } catch (_) {
      return null;
    }
  }

  Future<void> _pruneEmptyParents(String root, Directory parent) async {
    var current = parent;
    while (_isInside(root, current.absolute.path)) {
      try {
        if (!await current.list(followLinks: false).isEmpty) {
          return;
        }
        await current.delete();
      } on FileSystemException {
        return;
      }
      current = current.parent;
    }
  }

  bool _isInside(String root, String target) {
    final separator = Platform.pathSeparator;
    final prefix = root.endsWith(separator) ? root : '$root$separator';
    final left = Platform.isWindows ? prefix.toLowerCase() : prefix;
    final right = Platform.isWindows ? target.toLowerCase() : target;
    return right.startsWith(left);
  }

  String _bookName(
    String decoded,
    String extension, {
    required String fallback,
  }) {
    final cleaned = _safeName(decoded, fallback: fallback);
    final stem = _withoutExtension(cleaned);
    final base = stem.isEmpty ? fallback : stem;
    return extension.isEmpty ? base : '$base.$extension';
  }

  String _safeName(String raw, {required String fallback}) {
    final normalized = raw.replaceAll('\\', '/');
    final base = normalized.substring(normalized.lastIndexOf('/') + 1).trim();
    final cleaned = base
        .replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_')
        .replaceAll(RegExp(r'^\.+$'), '')
        .replaceAll(RegExp(r'[ .]+$'), '');
    return cleaned.isEmpty ? fallback : cleaned;
  }

  String _extensionOf(String name) {
    final normalized = name.replaceAll('\\', '/');
    final base = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = base.lastIndexOf('.');
    return dot < 0 || dot == base.length - 1
        ? ''
        : base.substring(dot + 1).toLowerCase();
  }

  String _withoutExtension(String name) {
    final normalized = name.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final base = normalized.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0
        ? name
        : normalized.substring(0, slash + 1 + dot);
  }

  String _child(String parent, String name) =>
      '$parent${Platform.pathSeparator}$name';

  String _parentOf(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index <= 0 ? path : path.substring(0, index);
  }

  PreparedBookDocument _error(String name, String message) =>
      (name: name, path: null, error: message);

  String _describe(Object error) {
    if (error is MissingPluginException) {
      return '当前平台暂不支持该格式的转换';
    }
    if (error is PlatformException) {
      final message = error.message?.trim();
      return message == null || message.isEmpty
          ? '文件转换失败（${error.code}）'
          : message;
    }
    if (error is FileSystemException) {
      return '无法读写文件：${error.message}';
    }
    if (error is FormatException) {
      return error.message;
    }
    return '文件转换失败';
  }
}
