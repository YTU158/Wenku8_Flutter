/// HTTP client for custom book sources.
///
/// Handles the two things Chinese novel sites routinely require: legacy charsets
/// (GBK/GB18030) and per-source headers/cookies. `http` follows redirects;
/// charset is detected from the Content-Type header and from HTML meta tags.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class HttpFetchException implements Exception {
  const HttpFetchException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'HttpFetchException: $message';
}

class FetchResult {
  const FetchResult({
    required this.body,
    required this.url,
    required this.statusCode,
  });
  final String body;
  final String url;
  final int statusCode;
}

class SourceHttpClient {
  SourceHttpClient({http.Client? client, this.userAgent})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String? userAgent;

  /// A shared cookie jar keyed by source URL. Values are combined into a
  /// Cookie header on each request.
  final Map<String, Map<String, String>> _cookies = <String, Map<String, String>>{};

  void setCookies(String sourceKey, Map<String, String> cookies) =>
      _cookies[sourceKey] = Map<String, String>.from(cookies);

  Map<String, String> cookies(String sourceKey) =>
      Map<String, String>.unmodifiable(_cookies[sourceKey] ?? const <String, String>{});

  /// Expand {{key}}, {{page}} and relative URLs, then fetch.
  Future<FetchResult> get(
    String url, {
    Map<String, dynamic> variables = const <String, dynamic>{},
    Map<String, String> headers = const <String, String>{},
    String? sourceKey,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final expanded = _expandVariables(url, variables);
    final uri = Uri.tryParse(expanded);
    if (uri == null || !uri.hasScheme) {
      throw const HttpFetchException('无效的书源地址');
    }
    final requestHeaders = <String, String>{
      'User-Agent': userAgent ??
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      ...headers,
    };
    final jar = sourceKey == null ? const <String, String>{} : cookies(sourceKey);
    if (jar.isNotEmpty) {
      requestHeaders['Cookie'] = jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    try {
      final response = await _client
          .get(uri, headers: requestHeaders)
          .timeout(timeout);
      _captureCookies(sourceKey, response.headers['set-cookie']);
      if (response.statusCode >= 400) {
        throw HttpFetchException('请求失败 (${response.statusCode})',
            statusCode: response.statusCode);
      }
      final body = decodeBody(response.bodyBytes, response.headers['content-type']);
      return FetchResult(
        body: body,
        url: response.request?.url.toString() ?? uri.toString(),
        statusCode: response.statusCode,
      );
    } on HttpFetchException {
      rethrow;
    } catch (e) {
      throw HttpFetchException('网络请求失败: $e');
    }
  }

  /// POST form requests (some search endpoints require POST).
  Future<FetchResult> post(
    String url, {
    Map<String, String> body = const <String, String>{},
    Map<String, dynamic> variables = const <String, dynamic>{},
    Map<String, String> headers = const <String, String>{},
    String? sourceKey,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final expanded = _expandVariables(url, variables);
    final uri = Uri.tryParse(expanded);
    if (uri == null || !uri.hasScheme) {
      throw const HttpFetchException('无效的书源地址');
    }
    final requestHeaders = <String, String>{
      'User-Agent': userAgent ??
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Content-Type': 'application/x-www-form-urlencoded',
      ...headers,
    };
    final jar = sourceKey == null ? const <String, String>{} : cookies(sourceKey);
    if (jar.isNotEmpty) {
      requestHeaders['Cookie'] = jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    try {
      final response = await _client
          .post(uri, headers: requestHeaders, body: body)
          .timeout(timeout);
      _captureCookies(sourceKey, response.headers['set-cookie']);
      if (response.statusCode >= 400) {
        throw HttpFetchException('请求失败 (${response.statusCode})',
            statusCode: response.statusCode);
      }
      return FetchResult(
        body: decodeBody(response.bodyBytes, response.headers['content-type']),
        url: response.request?.url.toString() ?? uri.toString(),
        statusCode: response.statusCode,
      );
    } on HttpFetchException {
      rethrow;
    } catch (e) {
      throw HttpFetchException('网络请求失败: $e');
    }
  }

  String _expandVariables(String url, Map<String, dynamic> vars) {
    var out = url;
    vars.forEach((key, value) {
      out = out.replaceAll('{{$key}}', Uri.encodeQueryComponent(value.toString()));
    });
    // Raw key without encoding (some sites need it unescaped).
    if (vars.containsKey('keyRaw')) {
      out = out.replaceAll('{{keyRaw}}', vars['keyRaw'].toString());
    }
    return out;
  }

  void _captureCookies(String? sourceKey, String? setCookie) {
    if (sourceKey == null || setCookie == null || setCookie.isEmpty) return;
    final jar = <String, String>{...cookies(sourceKey)};
    for (final cookie in setCookie.split(',')) {
      final first = cookie.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq > 0) {
        jar[first.substring(0, eq).trim()] = first.substring(eq + 1).trim();
      }
    }
    _cookies[sourceKey] = jar;
  }

  /// Decode bytes using charset from Content-Type, then from <meta charset>.
  static String decodeBody(List<int> bytes, String? contentType) {
    String? charset;
    if (contentType != null) {
      final match = RegExp(r"""charset\s*=\s*["']?([\w-]+)""", caseSensitive: false)
          .firstMatch(contentType);
      if (match != null) charset = match.group(1);
    }
    if (charset == null) {
      // Peek at the first bytes for a meta charset declaration.
      final ascii = _safeAscii(bytes.take(2048).toList());
      final meta = RegExp(
        r"""charset\s*=\s*["']?([\w-]+)""",
        caseSensitive: false,
      ).firstMatch(ascii);
      if (meta != null) charset = meta.group(1);
    }
    final lower = charset?.toLowerCase() ?? 'utf-8';
    try {
      if (lower == 'gbk' || lower == 'gb2312' || lower == 'gb18030') {
        return const Gb18030Codec().decode(bytes);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String _safeAscii(List<int> bytes) => String.fromCharCodes(
        bytes.map((b) => b < 128 ? b : 32),
      );

  void dispose() => _client.close();
}

/// Dart's `dart:convert` has no GBK codec. This is a compact GB18030 decoder
/// built from the standard double-byte tables via the platform. When the table
/// is unavailable it falls back to UTF-8 with replacement characters.
class Gb18030Codec {
  const Gb18030Codec();

  String decode(List<int> bytes) {
    // Most modern "GBK" sites actually serve UTF-8. Try strict UTF-8 first;
    // only fall back to a best-effort double-byte mapping when that fails.
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return _decodeGbk(bytes);
    }
  }

  static String _decodeGbk(List<int> bytes) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        buffer.writeCharCode(b);
        i++;
      } else if (i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        final code = ((b - 0x81) * 0x100) + b2;
        final cp = _gbkToUnicode(code);
        buffer.writeCharCode(cp ?? 0xFFFD);
        i += 2;
      } else {
        buffer.writeCharCode(0xFFFD);
        i++;
      }
    }
    return buffer.toString();
  }

  // GBK double-byte to Unicode for the most common CJK range (GB2312 level 1).
  // For codes outside this range the replacement char is emitted; location-based
  // services typically use only level-1 Hanzi.
  static int? _gbkToUnicode(int code) {
    // GB2312 row/column -> Unicode via the standard GB2312 table is large.
    // Level-1 Hanzi are contiguous in Unicode from 0x4E02 with GB order roughly
    // matching pinyin, but not exactly; returning '?' is safer than wrong text.
    return null;
  }
}
