import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'app_interactions.dart';
import 'book_source/book_source_store.dart' show isCustomSourceBook;
import 'catalog.dart';
import 'legacy_cover.dart';
import 'reader_illustrations.dart';

ReaderIllustrationCache novelCoverImageCache(Novel book) =>
    ReaderIllustrationCache(request: (url) async {
      if (isCustomSourceBook(book.id)) {
        final coverUrl = (url.isNotEmpty ? url : book.coverUrl) ?? '';
        if (coverUrl.isEmpty) {
          throw const FormatException('该书源未提供封面');
        }
        final uri = Uri.tryParse(coverUrl);
        if (uri == null) throw const FormatException('封面地址无效');
        final response = await http.get(uri).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw const FormatException('封面加载失败');
        }
        return Uint8List.fromList(response.bodyBytes);
      }
      return LegacyCover.bytes(book.id);
    });

Future<void> openNovelCoverImage(
  BuildContext context,
  Novel book, {
  required bool reduceMotion,
}) async {
  final url = book.coverUrl;
  if (url == null) return;
  await pushNovelPage<void>(
    context,
    ReaderIllustrationGallery(
      urls: [url],
      initialUrl: url,
      title: '小说封面',
      fileNamePrefix: book.title,
      cache: novelCoverImageCache(book),
    ),
    reduceMotion: reduceMotion,
  );
}
