/// Lightweight service locator for custom book-source services.
///
/// Avoids threading new objects through every widget constructor. Set once at
/// startup in main(); read from the settings entry point.
library;

import 'book_source_store.dart';
import 'custom_source_repository.dart';

class SourceLocator {
  static BookSourceStore? _store;
  static CustomSourceRepository? _repository;

  static void install({
    required BookSourceStore store,
    required CustomSourceRepository repository,
  }) {
    _store = store;
    _repository = repository;
  }

  static BookSourceStore? get store => _store;
  static CustomSourceRepository? get repository => _repository;
  static bool get available => _store != null;
}
