/// Extracts an image (manga) chapter's image URLs, in reading order,
/// from the engine's processed chapter content string.
///
/// This is the Dart twin of the bridge's native extractor
/// (`LegadoEngine.extractImages`), kept in lockstep with it: it runs
/// as a fallback when the bridge's own `images` list comes back empty
/// (an engine build whose extractor missed a shape), and its cleanup
/// half also sanitises the bridge's list. The rules mirror the fork's
/// own string scanners — DOM parsing is unusable here because manga
/// rules wrap each image as `<img src="URL,{"headers":{...}}">`, and
/// both jsoup and ksoup end the double-quoted src at the JSON's first
/// inner quote, truncating it to `URL,{`:
///
/// - `<img>` tags via the fork BookController's imgTagRegex (the src
///   capture tolerates one inner quote when the value continues to a
///   closing `}` — the URL-option suffix form);
/// - Markdown `![alt](url)` images;
/// - bare image-URL lines (BookController.isImageOrHttpLine's test).
///
/// A candidate keeps a COMPLETE `,{...}` suffix — the engine's
/// `resolveImageRequest` consumes it natively. A dangling, unbalanced
/// `,{` fragment (the remnant the engine's HtmlFormatter leaves when
/// it re-emits a tag through its DOM walk) is cut, keeping the bare
/// URL. Relative candidates are resolved against [baseUrl] (the
/// chapter's absolute URL when known, else the book's toc/book URL).
library;

final RegExp _imgSrcRegex = RegExp(
  r"""<img[^>]*\ssrc=['"]([^'"]*(?:['"][^>]+\})?)['"][^>]*>""",
  caseSensitive: false,
);
final RegExp _imgDataSrcRegex = RegExp(
  r"""<img[^>]*\sdata-src=['"]([^'"]*(?:['"][^>]+\})?)['"][^>]*>""",
  caseSensitive: false,
);
final RegExp _mdImgRegex = RegExp(r"""!\[[^\]]*\]\(([^\s\)]+)\)""");
final RegExp _imgTagRegex = RegExp(r'<img[^>]*>', caseSensitive: false);

const _imageExtensions = <String>[
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.avif',
];

/// Whether [line] (already trimmed) reads as a bare image URL, per the
/// fork BookController's isImageOrHttpLine test.
bool isLegadoImageUrlLine(String line) {
  if (line.isEmpty) return false;
  final lower = line.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      line.startsWith('//')) {
    return true;
  }
  final clean = line.split(',{').first.trim().toLowerCase();
  return _imageExtensions.any(clean.endsWith);
}

/// Cleans one raw image candidate: trims, cuts a dangling option
/// suffix, and rejects anything whose URL head was never a URL. Null
/// when the candidate does not survive.
///
/// Only the head (before `,{`) is held to the no-quotes/no-whitespace
/// rule: a complete suffix is the fork's URL-option JSON — its quotes
/// are the JSON's own, and the whole string, quotes included, is what
/// Legado's AnalyzeUrl consumes downstream.
String? cleanLegadoImageUrl(String raw) {
  // Dart's trim() also strips the U+3000 full-width indent the
  // engine's formatter prepends to bare text lines.
  var candidate = raw.trim();
  if (candidate.isEmpty) return null;
  final suffixAt = candidate.indexOf(',{');
  final String head;
  if (suffixAt >= 0 && !candidate.endsWith('}')) {
    // Incomplete option suffix (truncated upstream): the bare URL
    // before it is still fetchable.
    candidate = candidate.substring(0, suffixAt).trim();
    head = candidate;
  } else {
    head = suffixAt >= 0 ? candidate.substring(0, suffixAt) : candidate;
  }
  if (head.isEmpty) return null;
  // Quotes, markup debris or raw whitespace in the head mean this was
  // never a URL (a percent-encoded URL contains none of these).
  if (head.contains('"') ||
      head.contains("'") ||
      head.contains('<') ||
      head.contains('>') ||
      head.contains(RegExp(r'\s'))) {
    return null;
  }
  return candidate;
}

/// Resolves [candidate] (already cleaned) against [baseUrl], keeping
/// any `,{...}` option suffix intact — only the URL head is resolved.
String absolutizeLegadoImageUrl(String candidate, String baseUrl) {
  if (candidate.toLowerCase().startsWith('data:')) return candidate;
  final suffixAt = candidate.indexOf(',{');
  final head = suffixAt >= 0 ? candidate.substring(0, suffixAt) : candidate;
  final suffix = suffixAt >= 0 ? candidate.substring(suffixAt) : '';
  final lower = head.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return candidate;
  }
  final base = Uri.tryParse(baseUrl);
  if (base == null || !base.hasScheme) return candidate;
  try {
    return base.resolve(head).toString() + suffix;
  } catch (_) {
    return candidate;
  }
}

/// Sanitises a list of raw candidates (e.g. the bridge's own list):
/// cleaned, absolutized against [baseUrl], de-duplicated in order.
List<String> sanitizeLegadoImageUrls(
  Iterable<String> raw, {
  required String baseUrl,
}) {
  final seen = <String>{};
  final results = <String>[];
  for (final candidate in raw) {
    final cleaned = cleanLegadoImageUrl(candidate);
    if (cleaned == null) continue;
    final absolute = absolutizeLegadoImageUrl(cleaned, baseUrl);
    if (seen.add(absolute)) results.add(absolute);
  }
  return List.unmodifiable(results);
}

/// Parses [content] (the engine's processed chapter body) into the
/// chapter's image URLs in reading order.
List<String> parseLegadoImageUrls(String content, {required String baseUrl}) {
  if (content.trim().isEmpty) return const [];
  final raw = <String>[];
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.toLowerCase().contains('<img')) {
      // Tag by tag, so several images sharing one line all survive,
      // each with its own data-src-over-src preference.
      final tagUrls = <String>[];
      for (final tag in _imgTagRegex.allMatches(trimmed)) {
        final text = tag.group(0)!;
        final captured =
            _imgDataSrcRegex.firstMatch(text) ?? _imgSrcRegex.firstMatch(text);
        if (captured != null) tagUrls.add(captured.group(1)!);
      }
      if (tagUrls.isNotEmpty) {
        raw.addAll(tagUrls);
        continue;
      }
    }
    final md = _mdImgRegex.firstMatch(trimmed);
    if (md != null) {
      raw.add(md.group(1)!);
      continue;
    }
    if (isLegadoImageUrlLine(trimmed)) raw.add(trimmed);
  }
  return sanitizeLegadoImageUrls(raw, baseUrl: baseUrl);
}
