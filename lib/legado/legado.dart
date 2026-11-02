/// Dart-side bridge to the Legado book-source engine.
///
/// The engine itself runs natively (see ENGINE-study.md); this library is
/// only the typed channel client, its DTOs, and the pure search-result
/// merging used by the UI layer. Nothing here touches the UI.
library;

export 'legado_dto.dart';
export 'legado_engine_client.dart';
export 'search_merge.dart';
