/// A Legado-compatible book source definition.
///
/// Field names intentionally mirror the upstream `BookSource` JSON so that
/// sources exported from 阅读 / Legado can be imported verbatim. Unknown keys
/// are preserved in [extras] and written back on export.
class BookSource {
  const BookSource({
    required this.bookSourceUrl,
    required this.bookSourceName,
    this.bookSourceGroup = '',
    this.bookSourceType = 0,
    this.bookSourceComment = '',
    this.customOrder = 0,
    this.enabled = true,
    this.enabledSearch = true,
    this.enabledExplore = false,
    this.loginUrl = '',
    this.searchUrl = '',
    this.exploreUrl = '',
    this.ruleSearch = const SearchRule(),
    this.ruleBookInfo = const BookInfoRule(),
    this.ruleToc = const TocRule(),
    this.ruleContent = const ContentRule(),
    this.extras = const <String, dynamic>{},
  });

  final String bookSourceUrl;
  final String bookSourceName;
  final String bookSourceGroup;
  final int bookSourceType;
  final String bookSourceComment;
  final int customOrder;
  final bool enabled;
  final bool enabledSearch;
  final bool enabledExplore;
  final String loginUrl;
  final String searchUrl;
  final String exploreUrl;
  final SearchRule ruleSearch;
  final BookInfoRule ruleBookInfo;
  final TocRule ruleToc;
  final ContentRule ruleContent;
  final Map<String, dynamic> extras;

  /// Stable key: Legado identifies a source by its URL.
  String get key => bookSourceUrl.trim();

  bool get isValid => key.isNotEmpty && bookSourceName.trim().isNotEmpty;

  BookSource copyWith({
    String? bookSourceUrl,
    String? bookSourceName,
    String? bookSourceGroup,
    int? bookSourceType,
    String? bookSourceComment,
    int? customOrder,
    bool? enabled,
    bool? enabledSearch,
    bool? enabledExplore,
    String? loginUrl,
    String? searchUrl,
    String? exploreUrl,
    SearchRule? ruleSearch,
    BookInfoRule? ruleBookInfo,
    TocRule? ruleToc,
    ContentRule? ruleContent,
    Map<String, dynamic>? extras,
  }) => BookSource(
    bookSourceUrl: bookSourceUrl ?? this.bookSourceUrl,
    bookSourceName: bookSourceName ?? this.bookSourceName,
    bookSourceGroup: bookSourceGroup ?? this.bookSourceGroup,
    bookSourceType: bookSourceType ?? this.bookSourceType,
    bookSourceComment: bookSourceComment ?? this.bookSourceComment,
    customOrder: customOrder ?? this.customOrder,
    enabled: enabled ?? this.enabled,
    enabledSearch: enabledSearch ?? this.enabledSearch,
    enabledExplore: enabledExplore ?? this.enabledExplore,
    loginUrl: loginUrl ?? this.loginUrl,
    searchUrl: searchUrl ?? this.searchUrl,
    exploreUrl: exploreUrl ?? this.exploreUrl,
    ruleSearch: ruleSearch ?? this.ruleSearch,
    ruleBookInfo: ruleBookInfo ?? this.ruleBookInfo,
    ruleToc: ruleToc ?? this.ruleToc,
    ruleContent: ruleContent ?? this.ruleContent,
    extras: extras ?? this.extras,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'bookSourceUrl': bookSourceUrl,
    'bookSourceName': bookSourceName,
    'bookSourceGroup': bookSourceGroup,
    'bookSourceType': bookSourceType,
    'bookSourceComment': bookSourceComment,
    'customOrder': customOrder,
    'enabled': enabled,
    'enabledSearch': enabledSearch,
    'enabledExplore': enabledExplore,
    'loginUrl': loginUrl,
    'searchUrl': searchUrl,
    'exploreUrl': exploreUrl,
    'ruleSearch': ruleSearch.toJson(),
    'ruleBookInfo': ruleBookInfo.toJson(),
    'ruleToc': ruleToc.toJson(),
    'ruleContent': ruleContent.toJson(),
    ...extras,
  };

  factory BookSource.fromJson(Map<String, dynamic> json) {
    const known = <String>{
      'bookSourceUrl', 'bookSourceName', 'bookSourceGroup', 'bookSourceType',
      'bookSourceComment', 'customOrder', 'enabled', 'enabledSearch',
      'enabledExplore', 'loginUrl', 'searchUrl', 'exploreUrl',
      'ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent',
    };
    final extras = <String, dynamic>{};
    for (final entry in json.entries) {
      if (!known.contains(entry.key)) extras[entry.key] = entry.value;
    }
    return BookSource(
      bookSourceUrl: _str(json['bookSourceUrl']),
      bookSourceName: _str(json['bookSourceName']),
      bookSourceGroup: _str(json['bookSourceGroup']),
      bookSourceType: _int(json['bookSourceType'], fallback: 0),
      bookSourceComment: _str(json['bookSourceComment']),
      customOrder: _int(json['customOrder']),
      enabled: _bool(json['enabled'], fallback: true),
      enabledSearch: _bool(json['enabledSearch'], fallback: true),
      enabledExplore: _bool(json['enabledExplore']),
      loginUrl: _str(json['loginUrl']),
      searchUrl: _str(json['searchUrl']),
      exploreUrl: _str(json['exploreUrl']),
      ruleSearch: SearchRule.fromJson(_map(json['ruleSearch'])),
      ruleBookInfo: BookInfoRule.fromJson(_map(json['ruleBookInfo'])),
      ruleToc: TocRule.fromJson(_map(json['ruleToc'])),
      ruleContent: ContentRule.fromJson(_map(json['ruleContent'])),
      extras: Map.unmodifiable(extras),
    );
  }

  static String _str(Object? v) => v is String ? v : '';
  static int _int(Object? v, {int fallback = 0}) =>
      v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? fallback : fallback));
  static bool _bool(Object? v, {bool fallback = false}) =>
      v is bool ? v : (v is String ? v == '1' || v.toLowerCase() == 'true' : fallback);
  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
}

class SearchRule {
  const SearchRule({
    this.bookList = '',
    this.name = '',
    this.author = '',
    this.kind = '',
    this.wordCount = '',
    this.lastChapter = '',
    this.intro = '',
    this.coverUrl = '',
    this.bookUrl = '',
  });

  final String bookList, name, author, kind, wordCount;
  final String lastChapter, intro, coverUrl, bookUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'bookList': bookList, 'name': name, 'author': author, 'kind': kind,
    'wordCount': wordCount, 'lastChapter': lastChapter, 'intro': intro,
    'coverUrl': coverUrl, 'bookUrl': bookUrl,
  };

  factory SearchRule.fromJson(Map<String, dynamic> j) => SearchRule(
    bookList: BookSource._str(j['bookList']), name: BookSource._str(j['name']),
    author: BookSource._str(j['author']), kind: BookSource._str(j['kind']),
    wordCount: BookSource._str(j['wordCount']), lastChapter: BookSource._str(j['lastChapter']),
    intro: BookSource._str(j['intro']), coverUrl: BookSource._str(j['coverUrl']),
    bookUrl: BookSource._str(j['bookUrl']),
  );
}

class BookInfoRule {
  const BookInfoRule({
    this.name = '',
    this.author = '',
    this.kind = '',
    this.wordCount = '',
    this.lastChapter = '',
    this.intro = '',
    this.coverUrl = '',
    this.tocUrl = '',
    this.isComplete = '',
  });

  final String name, author, kind, wordCount, lastChapter;
  final String intro, coverUrl, tocUrl, isComplete;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name, 'author': author, 'kind': kind, 'wordCount': wordCount,
    'lastChapter': lastChapter, 'intro': intro, 'coverUrl': coverUrl,
    'tocUrl': tocUrl, 'isComplete': isComplete,
  };

  factory BookInfoRule.fromJson(Map<String, dynamic> j) => BookInfoRule(
    name: BookSource._str(j['name']), author: BookSource._str(j['author']),
    kind: BookSource._str(j['kind']), wordCount: BookSource._str(j['wordCount']),
    lastChapter: BookSource._str(j['lastChapter']), intro: BookSource._str(j['intro']),
    coverUrl: BookSource._str(j['coverUrl']), tocUrl: BookSource._str(j['tocUrl']),
    isComplete: BookSource._str(j['isComplete']),
  );
}

class TocRule {
  const TocRule({
    this.chapterList = '',
    this.chapterName = '',
    this.chapterUrl = '',
    this.isVip = '',
    this.updateTime = '',
    this.nextUrl = '',
  });

  final String chapterList, chapterName, chapterUrl, isVip, updateTime, nextUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chapterList': chapterList, 'chapterName': chapterName,
    'chapterUrl': chapterUrl, 'isVip': isVip, 'updateTime': updateTime,
    'nextUrl': nextUrl,
  };

  factory TocRule.fromJson(Map<String, dynamic> j) => TocRule(
    chapterList: BookSource._str(j['chapterList']),
    chapterName: BookSource._str(j['chapterName']),
    chapterUrl: BookSource._str(j['chapterUrl']),
    isVip: BookSource._str(j['isVip']),
    updateTime: BookSource._str(j['updateTime']),
    nextUrl: BookSource._str(j['nextUrl']),
  );
}

class ContentRule {
  const ContentRule({
    this.content = '',
    this.nextContentUrl = '',
    this.webJs = '',
    this.sourceRegex = '',
    this.replaceRegex = '',
    this.imageStyle = '',
  });

  final String content, nextContentUrl, webJs, sourceRegex, replaceRegex, imageStyle;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'content': content, 'nextContentUrl': nextContentUrl, 'webJs': webJs,
    'sourceRegex': sourceRegex, 'replaceRegex': replaceRegex, 'imageStyle': imageStyle,
  };

  factory ContentRule.fromJson(Map<String, dynamic> j) => ContentRule(
    content: BookSource._str(j['content']),
    nextContentUrl: BookSource._str(j['nextContentUrl']),
    webJs: BookSource._str(j['webJs']),
    sourceRegex: BookSource._str(j['sourceRegex']),
    replaceRegex: BookSource._str(j['replaceRegex']),
    imageStyle: BookSource._str(j['imageStyle']),
  );
}
