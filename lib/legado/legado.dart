/// Dart-side bridge to the Legado book-source engine.
///
/// The engine itself runs natively (see ENGINE-study.md); this library
/// carries the typed channel client and DTOs, the search-result
/// merging, the book registry/repository that adapt engine books onto
/// the host's catalog contract, and the discovery/search/source
/// widgets that plug them into the host's existing pages.
library;

export 'legado_book_registry.dart';
export 'legado_books.dart';
export 'legado_dto.dart';
export 'legado_engine_client.dart';
export 'legado_explore.dart';
export 'legado_novel_repository.dart';
export 'legado_search_controller.dart';
export 'legado_source_section.dart';
export 'search_merge.dart';
