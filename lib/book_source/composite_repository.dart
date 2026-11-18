/// Routes repository calls to the correct backing source by book ID.
///
/// The official Wenku8 repository owns small integer IDs; custom sources own
/// the reserved 0x50000000.. range. Search aggregates enabled sources.
library;

import '../catalog.dart';
import 'book_source_store.dart';
import 'custom_source_repository.dart';

class CompositeRepository extends NovelRepository {
  const CompositeRepository({
    required this.remote,
    required this.custom,
    required this.store,
  });

  final NovelRepository remote;
  final CustomSourceRepository custom;
  final BookSourceStore store;

  @override
  Future<List<Novel>> list() async => remote.list();

  @override
  Future<Novel?> find(int id) async {
    if (isCustomSourceBook(id)) return custom.find(id);
    return remote.find(id);
  }

  @override
  Future<List<Novel>> search(String query) async => (await searchPage(query)).items;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => remote.browse(sort: sort, page: page, refresh: refresh);

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    final official = await remote.searchPage(query, page: page, refresh: refresh);
    if (store.enabledSources.isEmpty) return official;
    final customPage = await custom.searchPage(query, page: page, refresh: refresh);
    final combined = <Novel>[...official.items, ...customPage.items];
    return NovelPage(
      items: List.unmodifiable(combined),
      page: page,
      totalItems: combined.length,
    );
  }

  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) async {
    final official = await remote.searchFilteredPage(
      query,
      field: field,
      page: page,
      refresh: refresh,
    );
    if (store.enabledSources.isEmpty) return official;
    final customPage = await custom.searchPage(query, page: page, refresh: refresh);
    final combined = <Novel>[...official.items, ...customPage.items];
    return NovelPage(
      items: List.unmodifiable(combined),
      page: page,
      totalItems: combined.length,
    );
  }

  @override
  Future<Novel> detail(Novel novel) async {
    if (isCustomSourceBook(novel.id)) return custom.detail(novel);
    return remote.detail(novel);
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    if (isCustomSourceBook(id)) return custom.chapters(id);
    return remote.chapters(id);
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (isCustomSourceBook(novelId)) {
      return custom.chapterContent(novelId, chapter);
    }
    return remote.chapterContent(novelId, chapter);
  }
}
