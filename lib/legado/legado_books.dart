import '../catalog.dart';
import 'legado_book_registry.dart';
import 'legado_engine_client.dart';
import 'legado_novel_repository.dart';

/// Process-wide singletons for the Legado wiring, so the repository
/// installed in `main.dart` and the controllers/widgets created by the
/// home shell all share one client, one registry and one repository.
abstract final class LegadoBooks {
  static LegadoEngineClient? _client;
  static LegadoBookRegistry? _registry;
  static LegadoNovelRepository? _repository;

  static LegadoEngineClient get client => _client ??= LegadoEngineClient();

  static LegadoBookRegistry get registry => _registry ??= LegadoBookRegistry();

  /// The shared registry when it has been created already (detail page
  /// source section); null before any Legado flow ran in this process.
  static LegadoBookRegistry? get registryOrNull => _registry;

  static LegadoNovelRepository get repository =>
      _repository ??= LegadoNovelRepository(client: client, registry: registry);

  /// The root repository to install in place of the plain wenku remote:
  /// engine books route to the engine, everything else is untouched.
  static LegadoDispatchRepository dispatch(NovelRepository legacy) =>
      LegadoDispatchRepository(legacy: legacy, legado: repository);
}
