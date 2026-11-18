/// A NovelRepository backed by user-imported Legado book sources.
///
/// It maps scraped results into the app's source-neutral [Novel] model so that
/// every shelf/detail/reader widget works unchanged. Books get IDs in the
/// reserved custom range (0x50000000..), kept stable by [BookSourceStore].
library;

import 'dart:async';

import 'package:flutter/material.dart' show Color;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../catalog.dart';
import 'analyze_rule.dart';
import 'book_source_model.dart';
import 'book_source_store.dart';
import 'js_runtime.dart';
import 'source_http.dart';
import 'xpath_engine.dart';

class CustomSourceRepository extends NovelRepository {
  CustomSourceRepository({
    required this.store,
    required this.http,
    JsRuntime? js,
  }) : js = js ?? JsRuntime();

  final BookSourceStore store;
  final SourceHttpClient http;
  final JsRuntime js;

  final Map<int, Novel> _known = <int, Novel>{};
  final Map<int, BookSource> _bookSources = <int, BookSource>{};
  final Map<int, String> _bookUrls = <int, String>{};
  final Map<int, List<NovelChapter>> _chapters = <int, List<NovelChapter>>{};
  final Map<int, String> _tocUrls = <int, String>{};
  final Map<String, Future<NovelPage>> _searchPages = <String, Future<NovelPage>>{};
  final Map<(int, int), String> _chapterUrls = <(int, int), String>{};
  bool _restored = false;

  /// Restore persisted book->source routing so shelf books work after restart.
  void _restore() {
    if (_restored) return;
    _restored = true;
    store.bookRoutes.forEach((id, route) {
      final sourceKey = route['source'];
      final bookUrl = route['url'];
      if (sourceKey == null || bookUrl == null) return;
      final source = store.source(sourceKey);
      if (source == null) return;
      _bookSources[id] = source;
      _bookUrls[id] = bookUrl;
      final toc = route['toc'];
      if (toc != null) _tocUrls[id] = toc;
      // Chapter URLs are stored as url_1, url_2, ...
      for (final entry in route.entries) {
        final m = RegExp(r'^url_(\d+)$').firstMatch(entry.key);
        if (m != null) {
          final cid = int.tryParse(m.group(1)!);
          if (cid != null) _chapterUrls[(id, cid)] = entry.value;
        }
      }
    });
  }

  /// Expose which source a book belongs to (for the source badge in UI).
  /// Fetch a remote subscription URL and return its raw JSON text.
  Future<String> fetchSourceSubscription(String url) async {
    final response = await http.get(url);
    return response.body;
  }

  /// Test a source by issuing a search for a common term and reporting the
  /// number of results found.
  Future<String> testSource(BookSource source) async {
    if (source.searchUrl.isEmpty) return '该书源未配置搜索地址';
    try {
      final variables = <String, dynamic>{
        'key': '测试',
        'keyRaw': '测试',
        'page': 1,
      };
      final response = await http.get(
        source.searchUrl,
        variables: variables,
        sourceKey: source.key,
      );
      final ruleSearch = source.ruleSearch;
      if (ruleSearch.bookList.isEmpty) {
        return '连接成功，但未配置书籍列表规则';
      }
      final document = _parseHtml(response.body);
      if (document == null) return '连接成功，但返回内容无法解析';
      final elements = _selectElements(document, ruleSearch.bookList);
      return '测试成功，匹配到 ${elements.length} 个结果';
    } catch (e) {
      return '测试失败: $e';
    }
  }

  BookSource? sourceOf(int novelId) {
    _restore();
    return _bookSources[novelId];
  }

  bool handles(int novelId) {
    _restore();
    return isCustomSourceBook(novelId) && _bookSources.containsKey(novelId);
  }

  static const _palettes = <List<Color>>[
    [Color(0xFF5E87B8), Color(0xFF222C5B)],
    [Color(0xFF66C9BC), Color(0xFF276A8F)],
    [Color(0xFFE6A5B7), Color(0xFF8F658E)],
    [Color(0xFFE9B277), Color(0xFFB76E6E)],
  ];

  @override
  Future<List<Novel>> list() async {
    // Custom sources have no global catalogue; books only appear once found
    // via search and saved. Return what is known this session.
    return List.unmodifiable(_known.values);
  }

  @override
  Future<Novel?> find(int id) async {
    _restore();
    final known = _known[id];
    if (known != null) return known;
    // Cold start: rebuild a minimal Novel from the shelf's persisted snapshot.
    final route = store.bookRoute(id);
    if (route == null) return null;
    final snapshot = store.readNovelSnapshot(id);
    if (snapshot == null) return null;
    try {
      final novel = Novel.fromSnapshot(snapshot);
      _known[id] = novel;
      return novel;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Novel>> search(String query) async =>
      (await searchPage(query)).items;

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return NovelPage.fromItems(const <Novel>[], page);
    final key = 'all:$term:$page:${refresh ? DateTime.now().millisecondsSinceEpoch : 0}';
    if (!refresh) {
      final pending = _searchPages[key];
      if (pending != null) return pending;
    }
    final request = _doSearch(term, page);
    _searchPages[key] = request;
    try {
      return await request;
    } finally {
      _searchPages.remove(key);
    }
  }

  Future<NovelPage> _doSearch(String term, int page) async {
    final books = <Novel>[];
    final futures = <Future<List<Novel>>>[];
    for (final source in store.enabledSources) {
      if (!source.enabledSearch || source.searchUrl.isEmpty) continue;
      futures.add(_searchInSource(source, term, page));
    }
    final results = await Future.wait(futures, eagerError: false);
    for (final batch in results) {
      books.addAll(batch);
    }
    // De-duplicate by title+author.
    final seen = <String>{};
    final unique = books.where((b) {
      final k = '${b.title}|${b.author}';
      return seen.add(k);
    }).toList();
    return NovelPage(items: List.unmodifiable(unique), page: page);
  }

  Future<List<Novel>> _searchInSource(BookSource source, String term, int page) async {
    try {
      final url = source.searchUrl;
      final variables = <String, dynamic>{
        'key': term,
        'keyRaw': term,
        'page': page,
      };
      final FetchResult response;
      if (url.contains('POST:') || source.extras['searchMethod'] == 'POST') {
        final clean = url.replaceFirst('POST:', '');
        response = await http.post(
          clean,
          body: {'keyword': term, 'page': '$page'},
          variables: variables,
          sourceKey: source.key,
        );
      } else {
        response = await http.get(url, variables: variables, sourceKey: source.key);
      }

      final ruleSearch = source.ruleSearch;
      if (ruleSearch.bookList.isEmpty) return const <Novel>[];

      // Select each book element by re-parsing the raw HTML with the list rule,
      // then evaluate per-field rules with that element as the content root.
      final document = _parseHtml(response.body);
      if (document == null) return const <Novel>[];
      final bookElements = _selectElements(document, ruleSearch.bookList);
      final result = <Novel>[];
      for (final element in bookElements.entries) {
        final html = element.value;
        final fieldRule = AnalyzeRule(js: js, variables: RuleVariables.search(term, page))
          ..setContent(html);
        final bookUrl = fieldRule.getString(ruleSearch.bookUrl);
        final title = fieldRule.getString(ruleSearch.name);
        if (title.isEmpty || bookUrl.isEmpty) continue;
        final absoluteUrl = _resolveUrl(bookUrl, response.url);
        final id = store.idFor(source.key, absoluteUrl);
        _bookSources[id] = source;
        _bookUrls[id] = absoluteUrl;
        store.saveBookRoute(id, sourceKey: source.key, bookUrl: absoluteUrl);
        final novel = Novel(
          id: id,
          title: title,
          author: fieldRule.getString(ruleSearch.author, defaultValue: '佚名'),
          genre: _normalizeGenre(fieldRule.getString(ruleSearch.kind)),
          summary: fieldRule.getString(ruleSearch.intro, defaultValue: '点击查看作品介绍与目录。'),
          colors: _palettes[id % _palettes.length],
          coverUrl: _resolveUrl(fieldRule.getString(ruleSearch.coverUrl), response.url),
          lastUpdate: _nonNull(fieldRule.getString(ruleSearch.lastChapter)),
          isComplete: false,
        );
        _known[id] = novel;
        result.add(novel);
      }
      return result;
    } catch (_) {
      return const <Novel>[];
    }
  }

  @override
  Future<Novel> detail(Novel novel) async {
    if (!isCustomSourceBook(novel.id)) return novel;
    _restore();
    final source = _bookSources[novel.id];
    final url = _bookUrls[novel.id];
    if (source == null || url == null) return novel;
    try {
      final response = await http.get(url, sourceKey: source.key);
      final rule = AnalyzeRule(js: js, variables: RuleVariables(const {'key': '', 'page': 1}))
        ..setContent(response.body);
      final info = source.ruleBookInfo;
      final title = rule.getString(info.name, defaultValue: novel.title);
      final tocUrl = rule.getString(info.tocUrl);
      if (tocUrl.isNotEmpty) {
        final absoluteToc = _resolveUrl(tocUrl, response.url);
        _tocUrls[novel.id] = absoluteToc;
        store.saveBookRoute(novel.id, tocUrl: absoluteToc);
      }
      final updated = Novel(
        id: novel.id,
        title: title,
        author: _or(rule.getString(info.author), novel.author),
        genre: _or(_normalizeGenre(rule.getString(info.kind)), novel.genre),
        summary: _or(rule.getString(info.intro), novel.summary),
        colors: novel.colors,
        isComplete: _parseComplete(rule.getString(info.isComplete)),
        coverUrl: _or(_resolveUrl(rule.getString(info.coverUrl), response.url), novel.coverUrl),
        lastUpdate: _or(_nonNull(rule.getString(info.lastChapter)), novel.lastUpdate),
        chapterCount: novel.chapterCount,
      );
      _known[novel.id] = updated;
      return updated;
    } catch (_) {
      return novel;
    }
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    _restore();
    final cached = _chapters[id];
    if (cached != null) return cached;
    final source = _bookSources[id];
    final bookUrl = _bookUrls[id];
    if (source == null || bookUrl == null) return const <NovelChapter>[];
    try {
      final tocUrl = _tocUrls[id] ?? bookUrl;
      final response = await http.get(tocUrl, sourceKey: source.key);
      final rule = AnalyzeRule(js: js, variables: RuleVariables(const {'key': '', 'page': 1}))
        ..setContent(response.body);
      final listRule = source.ruleToc.chapterList;
      if (listRule.isEmpty) return const <NovelChapter>[];
      final document = _parseHtml(response.body);
      if (document == null) return const <NovelChapter>[];
      final elements = _selectElements(document, listRule);
      final chapters = <NovelChapter>[];
      var index = 0;
      for (final entry in elements.entries) {
        final chapterRule = AnalyzeRule(js: js, variables: RuleVariables(const {'key': '', 'page': 1}))
          ..setContent(entry.value);
        final title = chapterRule.getString(source.ruleToc.chapterName);
        final url = chapterRule.getString(source.ruleToc.chapterUrl);
        if (title.isEmpty) continue;
        final chapterId = index + 1;
        chapters.add(NovelChapter(
          title,
          '',
          id: chapterId,
          volumeId: 0,
          volumeTitle: '',
        ));
        final absoluteChapter = _resolveUrl(url, response.url);
        _chapterUrls.putIfAbsent((id, chapterId), () => absoluteChapter);
        store.saveBookRoute(id, extra: {'url_$chapterId': absoluteChapter});
        index++;
      }
      _chapters[id] = List.unmodifiable(chapters);
      return chapters;
    } catch (_) {
      return const <NovelChapter>[];
    }
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    _restore();
    final source = _bookSources[novelId];
    if (source == null) return chapter.content;
    var url = _chapterUrls[(novelId, chapter.id)];
    if (url == null || url.isEmpty) {
      // Cold start: the chapter URL map may be empty while the route is known.
      await chapters(novelId);
      url = _chapterUrls[(novelId, chapter.id)];
    }
    if (url == null || url.isEmpty) return chapter.content;
    try {
      final response = await http.get(url, sourceKey: source.key);
      final rule = AnalyzeRule(js: js, variables: RuleVariables(const {'key': '', 'page': 1}))
        ..setContent(response.body);
      var content = rule.getString(source.ruleContent.content);
      // Convert <br> to newlines and strip remaining tags for the reader.
      content = _cleanContent(content);
      return content;
    } catch (_) {
      return chapter.content;
    }
  }

  // ---- helpers -----------------------------------------------------------

  dom.Document? _parseHtml(String html) {
    try {
      return html_parser.parse(html);
    } catch (_) {
      return null;
    }
  }

  /// Select elements by a CSS/XPath list rule; returns index->outerHtml so each
  /// element can be analyzed independently.
  Map<int, String> _selectElements(
    dom.Document document,
    String listRule,
  ) {
    var selector = listRule.trim();
    if (selector.startsWith('@css:')) selector = selector.substring(5);
    if (selector.startsWith('@@')) selector = selector.substring(2);
    // Strip trailing attribute if present (list rule should select elements).
    final at = selector.lastIndexOf('@');
    if (at > 0) selector = selector.substring(0, at);

    final result = <int, String>{};
    try {
      final elements = document.querySelectorAll(selector);
      for (var i = 0; i < elements.length; i++) {
        result[i] = elements[i].outerHtml;
      }
    } catch (_) {
      // Try XPath via the standalone engine.
      final engine = XPathEngine(document);
      final nodes = engine.select(selector);
      for (var i = 0; i < nodes.length; i++) {
        result[i] = nodes[i].toString();
      }
    }
    return result;
  }

  static String _resolveUrl(String url, String base) {
    final value = url.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    final baseUri = Uri.tryParse(base);
    if (baseUri == null) return value;
    if (value.startsWith('//')) return '${baseUri.scheme}:$value';
    if (value.startsWith('/')) return '${baseUri.scheme}://${baseUri.authority}$value';
    return baseUri.resolve(value).toString();
  }

  static String _normalizeGenre(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '自定义书源';
    return value.replaceAll(RegExp(r'\s+'), ' · ');
  }

  static String _cleanContent(String raw) {
    return raw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static bool _parseComplete(String value) =>
      value.contains('完结') || value.contains('完本') || value == '1';

  static String _or(String first, String fallback) =>
      first.isEmpty ? fallback : first;
  static String? _nonNull(String value) => value.isEmpty ? null : value;
}
