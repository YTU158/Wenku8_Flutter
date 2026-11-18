/// Persistent store for custom book sources, backed by shared_preferences.
///
/// Stores the raw source JSON (verbatim Legado format) so imports round-trip
/// without loss. Also persists the URL<->int identity mapping for source books
/// and chapters, because Novel uses integer IDs throughout the app.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'book_source_model.dart';

const _kSources = 'custom_book_sources_v1';
const _kBookIdCounter = 'custom_book_id_counter_v1';

/// Base of the reserved ID range for custom-source books.
/// 0x50000000 .. 0x5FFFFFFF — below local books (0x60000000) and above the
/// small integer IDs used by the official Wenku8 API.
const int customBookIdStart = 0x50000000;
const int customBookIdEnd = 0x60000000;

bool isCustomSourceBook(int id) =>
    id >= customBookIdStart && id < customBookIdEnd;

class BookSourceStore {
  BookSourceStore(this._prefs);

  final SharedPreferences _prefs;
  List<BookSource>? _cache;
  Map<int, _Identity>? _identities;

  List<BookSource> get sources {
    final cache = _cache;
    if (cache != null) return List.unmodifiable(cache);
    final raw = _prefs.getStringList(_kSources) ?? const <String>[];
    final loaded = <BookSource>[];
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) {
          final source = BookSource.fromJson(decoded);
          if (source.isValid) loaded.add(source);
        }
      } catch (_) {}
    }
    loaded.sort((a, b) => a.customOrder.compareTo(b.customOrder));
    _cache = loaded;
    return List.unmodifiable(loaded);
  }

  List<BookSource> get enabledSources =>
      sources.where((s) => s.enabled).toList();

  BookSource? source(String key) {
    for (final s in sources) {
      if (s.key == key) return s;
    }
    return null;
  }

  Future<void> save(List<BookSource> list) async {
    final encoded = list.map((s) => jsonEncode(s.toJson())).toList();
    await _prefs.setStringList(_kSources, encoded);
    _cache = List<BookSource>.from(list);
  }

  Future<void> upsert(BookSource source) async {
    if (!source.isValid) return;
    final next = <BookSource>[...sources.where((s) => s.key != source.key), source]
      ..sort((a, b) => a.customOrder.compareTo(b.customOrder));
    await save(next);
  }

  Future<void> remove(String key) async {
    await save(sources.where((s) => s.key != key).toList());
  }

  Future<void> setEnabled(String key, bool enabled) async {
    final existing = source(key);
    if (existing == null) return;
    await upsert(existing.copyWith(enabled: enabled));
  }

  /// Import a Legado export: a single object, a JSON array, or a JSON-encoded
  /// string containing either. Returns the number of valid sources imported.
  Future<int> importJson(String text) async {
    final parsed = _parseSources(text);
    if (parsed.isEmpty) return 0;
    final merged = <String, BookSource>{for (final s in sources) s.key: s};
    for (final s in parsed) {
      merged[s.key] = s;
    }
    await save(merged.values.toList());
    return parsed.length;
  }

  static List<BookSource> _parseSources(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const <BookSource>[];
    dynamic value;
    try {
      value = jsonDecode(trimmed);
    } catch (_) {
      return const <BookSource>[];
    }
    // Sometimes the payload is a JSON string containing JSON.
    if (value is String) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const <BookSource>[];
      }
    }
    final list = <dynamic>[];
    if (value is List) {
      list.addAll(value);
    } else if (value is Map<String, dynamic>) {
      if (value.containsKey('bookSourceUrl')) {
        list.add(value);
      } else {
        // Wrappers like {"sources":[...]} or {"data":[...]}.
        for (final key in ['sources', 'data', 'bookSources', 'list']) {
          final inner = value[key];
          if (inner is List) {
            list.addAll(inner);
            break;
          }
        }
      }
    }
    final result = <BookSource>[];
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        final source = BookSource.fromJson(item);
        if (source.isValid) result.add(source);
      } else if (item is String) {
        try {
          final decoded = jsonDecode(item);
          if (decoded is Map<String, dynamic>) {
            final source = BookSource.fromJson(decoded);
            if (source.isValid) result.add(source);
          }
        } catch (_) {}
      }
    }
    return result;
  }

  String exportJson({Iterable<BookSource>? only}) =>
      jsonEncode((only ?? sources).map((s) => s.toJson()).toList());

  // ---- Identity mapping (string URL -> stable int ID) --------------------

  Map<int, _Identity> get identities {
    final cache = _identities;
    if (cache != null) return cache;
    final loaded = <int, _Identity>{};
    final raw = _prefs.getString('custom_book_identities_v1');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          final id = int.tryParse(key);
          if (id == null || value is! Map<String, dynamic>) return;
          loaded[id] = _Identity(
            sourceKey: (value['source'] as String?) ?? '',
            bookUrl: (value['url'] as String?) ?? '',
          );
        });
      } catch (_) {}
    }
    _identities = loaded;
    return loaded;
  }

  /// Allocate (or reuse) a stable integer ID for a source book URL.
  int idFor(String sourceKey, String bookUrl) {
    final map = identities;
    for (final entry in map.entries) {
      if (entry.value.sourceKey == sourceKey && entry.value.bookUrl == bookUrl) {
        return entry.key;
      }
    }
    final id = customBookIdStart +
        _stableHash('$sourceKey\u0000$bookUrl') %
            (customBookIdEnd - customBookIdStart);
    // Resolve collisions deterministically.
    var candidate = id;
    while (map.containsKey(candidate) &&
        !(map[candidate]!.sourceKey == sourceKey &&
            map[candidate]!.bookUrl == bookUrl)) {
      candidate++;
      if (candidate >= customBookIdEnd) candidate = customBookIdStart;
    }
    map[candidate] = _Identity(sourceKey: sourceKey, bookUrl: bookUrl);
    unawaited(_persistIdentities());
    return candidate;
  }

  _Identity? identity(int id) => identities[id];

  /// Extra per-book routing data: source key, book URL and toc URL.
  Map<int, Map<String, String>>? _bookRoutes;

  Map<int, Map<String, String>> get bookRoutes {
    final cache = _bookRoutes;
    if (cache != null) return cache;
    final loaded = <int, Map<String, String>>{};
    final raw = _prefs.getString('custom_book_routes_v1');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          final id = int.tryParse(key);
          if (id == null || value is! Map<String, dynamic>) return;
          loaded[id] = value.map((k, v) => MapEntry(k, v.toString()));
        });
      } catch (_) {}
    }
    _bookRoutes = loaded;
    return loaded;
  }

  void saveBookRoute(
    int id, {
    String? sourceKey,
    String? bookUrl,
    String? tocUrl,
    Map<String, String>? extra,
  }) {
    final routes = bookRoutes;
    final entry = <String, String>{...routes[id] ?? const <String, String>{}};
    if (sourceKey != null) entry['source'] = sourceKey;
    if (bookUrl != null) entry['url'] = bookUrl;
    if (tocUrl != null) entry['toc'] = tocUrl;
    if (extra != null) entry.addAll(extra);
    routes[id] = entry;
    unawaited(_persistRoutes());
  }

  Map<String, String>? bookRoute(int id) => bookRoutes[id];

  /// Read the Novel snapshot the shelf persisted under `novel_meta_<id>`.
  Map<String, dynamic>? readNovelSnapshot(int id) {
    final raw = _prefs.getString('novel_meta_$id');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistRoutes() async {
    await _prefs.setString('custom_book_routes_v1', jsonEncode(bookRoutes));
  }

  Future<void> _persistIdentities() async {
    final encoded = identities.map(
      (key, value) => MapEntry(
        '$key',
        {'source': value.sourceKey, 'url': value.bookUrl},
      ),
    );
    await _prefs.setString('custom_book_identities_v1', jsonEncode(encoded));
  }

  static int _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final code in input.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }
}

class _Identity {
  const _Identity({required this.sourceKey, required this.bookUrl});
  final String sourceKey;
  final String bookUrl;
}

// Avoid importing dart:async just for unawaited in a hot path.
void unawaited<T>(Future<T> future) {
  future.ignore();
}
