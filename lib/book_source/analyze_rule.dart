/// Legado-compatible rule analyzer.
///
/// A rule is a chain of expressions. Each expression is detected as CSS, XPath,
/// JSONPath, JS, regex or plain text and applied to the current result. Chain
/// operators:
///   &&  feed each element into the next rule (map)
///   ||  first non-empty wins
///   ##pattern##replacement  regex净化 (global replace, trailing ### = first only)
/// Template `{{ ... }}` and `@get:{key}` are expanded before evaluation.
library;

import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import 'js_runtime.dart';
import 'json_path.dart';
import 'xpath_engine.dart';

/// Variables shared across rules of one request (key, page, book, source, ...).
class RuleVariables {
  RuleVariables(this._values);
  final Map<String, dynamic> _values;
  final Map<String, String> _store = <String, String>{};

  factory RuleVariables.search(String key, int page) =>
      RuleVariables({'key': key, 'page': page});

  dynamic operator [](String key) => _values[key];
  void operator []=(String key, dynamic value) => _values[key] = value;

  void put(String key, String value) => _store[key] = value;
  String? get(String key) => _store[key];

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._values,
    ..._store,
  };
}

class AnalyzeRule {
  AnalyzeRule({
    required this.js,
    RuleVariables? variables,
  }) : variables = variables ?? RuleVariables(const <String, dynamic>{});

  final JsRuntime js;
  final RuleVariables variables;
  dom.Document? _document;
  dynamic _json;
  String _content = '';
  bool _isJson = false;

  /// Feed raw HTML or JSON content into the analyzer.
  AnalyzeRule setContent(String content) {
    _content = content;
    final trimmed = content.trimLeft();
    _isJson = trimmed.startsWith('{') || trimmed.startsWith('[');
    if (_isJson) {
      try {
        _json = jsonDecode(content);
      } catch (_) {
        _isJson = false;
        _json = null;
      }
    }
    if (!_isJson) {
      try {
        _document = html_parser.parse(content);
      } catch (_) {
        _document = null;
      }
    }
    return this;
  }

  /// Extract a single string.
  String getString(String? rule, {String defaultValue = ''}) {
    if (rule == null || rule.trim().isEmpty) return defaultValue;
    final values = getList(rule);
    if (values.isEmpty) return defaultValue;
    return values.first.trim();
  }

  /// Extract a list of strings following the rule chain.
  List<String> getList(String? rule) {
    if (rule == null || rule.trim().isEmpty) return const <String>[];
    final expanded = _makeUpRule(rule);
    // OR chains: first non-empty branch wins.
    final orParts = _splitTopLevel(expanded, '||');
    if (orParts.length > 1) {
      for (final part in orParts) {
        final result = _evalChain(part);
        if (result.isNotEmpty) return result;
      }
      return const <String>[];
    }
    return _evalChain(expanded);
  }

  /// Evaluate the raw content itself (e.g. a JS rule over the whole page).
  String evaluate(String rule) => getString(rule);

  List<String> _evalChain(String chain) {
    // AND chains: split, evaluate each against current nodes, flatten.
    final andParts = _splitTopLevel(chain, '&&');
    if (andParts.length > 1) {
      List<String> current = <String>[''];
      // First part evaluates against the document; later parts re-set content.
      for (var i = 0; i < andParts.length; i++) {
        final part = andParts[i].trim();
        if (i == 0) {
          current = _evalChain(part);
        } else {
          final expanded = _expandWithEach(part, current);
          current = expanded;
        }
      }
      return current.where((s) => s.isNotEmpty).toList();
    }
    return _evalSingle(chain);
  }

  List<String> _expandWithEach(String part, List<String> inputs) {
    final out = <String>[];
    for (final input in inputs) {
      setContent(input);
      out.addAll(_evalSingle(part));
    }
    return out;
  }

  List<String> _evalSingle(String raw) {
    var rule = raw.trim();
    if (rule.isEmpty) return const <String>[];

    // Regex replacement chain: rule##pattern##replacement (### = first only).
    String? replacePattern, replacement;
    bool firstOnly = false;
    final replaceIdx = _indexOfTopLevel(rule, '##');
    if (replaceIdx >= 0) {
      final after = rule.substring(replaceIdx + 2);
      rule = rule.substring(0, replaceIdx).trim();
      final parts = _splitReplace(after);
      if (parts.length >= 2) {
        replacePattern = parts[0];
        replacement = parts[1];
        firstOnly = parts.length >= 3;
      }
    }

    List<String> values = _extract(rule);

    if (replacePattern != null && replacement != null) {
      try {
        final re = RegExp(replacePattern, multiLine: true, dotAll: false);
        values = values.map((value) {
          return firstOnly
              ? value.replaceFirstMapped(re, (m) => _expandGroups(replacement!, m as RegExpMatch))
              : value.replaceAllMapped(re, (m) => _expandGroups(replacement!, m as RegExpMatch));
        }).toList();
      } catch (_) {
        // Invalid regex: keep original values.
      }
    }
    return values.where((s) => s.isNotEmpty).toList();
  }

  String _expandGroups(String replacement, RegExpMatch match) {
    var out = replacement;
    for (var i = 0; i <= match.groupCount; i++) {
      out = out.replaceAll('\$$i', match.group(i) ?? '');
    }
    return out;
  }

  List<String> _extract(String rule) {
    if (rule.isEmpty) return const <String>[];

    // AllInOne regex mode: prefix ':'.
    if (rule.startsWith(':')) {
      return _regexCapture(rule.substring(1), all: true);
    }
    // JS mode: @js: prefix or bare JS markers.
    if (rule.startsWith('@js:')) {
      final result = _runJs(rule.substring(4));
      return result.isEmpty ? const <String>[] : <String>[result];
    }
    // Nested {{ }} pure template already expanded in makeUp; if still present
    // it is a JS expression that must run.
    if (_looksLikeJs(rule)) {
      final result = _runJs(rule);
      return result.isEmpty ? const <String>[] : <String>[result];
    }
    // JSONPath.
    if (_isJson) {
      final jp = _stripPrefix(rule, 'json');
      if (jp.startsWith('\$') || rule.startsWith('@json:') || rule.startsWith('\$')) {
        return JsonPath.evaluate(_json, jp).map(_stringify).where((s) => s.isNotEmpty).toList();
      }
    }
    // XPath.
    final xp = _stripPrefix(rule, 'xpath');
    if (rule.startsWith('@XPath:') ||
        rule.startsWith('@xpath:') ||
        xp.startsWith('/')) {
      final engine = XPathEngine(_document ?? html_parser.parse('<html></html>'));
      final result = engine.evaluate(xp);
      if (result.text != null) {
        return result.text!.isEmpty ? const <String>[] : <String>[result.text!];
      }
      return result.nodes.map((n) => n.text?.trim() ?? '').where((s) => s.isNotEmpty).toList();
    }
    // CSS (default mode). Supports `selector@attr` and `@@selector@attr`.
    final css = _stripPrefix(rule, 'css');
    return _cssQuery(css);
  }

  List<String> _cssQuery(String rule) {
    final document = _document;
    if (document == null) return const <String>[];
    var selector = rule;
    String? attr;
    // `selector@attr` — split on the last @ that is not a css escape.
    final at = selector.lastIndexOf('@');
    if (at > 0) {
      attr = selector.substring(at + 1).trim();
      selector = selector.substring(0, at).trim();
    }
    if (selector.startsWith('@@')) selector = selector.substring(2);
    if (selector.isEmpty) selector = 'body';

    List<dom.Element> elements;
    try {
      elements = document.querySelectorAll(selector).toList();
    } catch (_) {
      return const <String>[];
    }
    if (attr == null || attr.isEmpty || attr == 'text' || attr == 'text()') {
      return elements
          .map((e) => e.text.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    if (attr == 'html' || attr == 'outerHtml') {
      return elements.map((e) => e.outerHtml).toList();
    }
    if (attr == 'innerHtml' || attr == 'innerHTML') {
      return elements.map((e) => e.innerHtml).toList();
    }
    final wantedAttr = (attr ?? '').toLowerCase();
    return elements
        .map((e) {
          final attrs = e.attributes;
          String? found;
          for (final k in attrs.keys) {
            final keyName = k.toString();
            if (keyName.toLowerCase() == wantedAttr) {
              found = keyName;
              break;
            }
          }
          return found == null ? '' : (attrs[found] ?? '');
        })
        .where((s) => s.isNotEmpty)
        .toList();
  }

  List<String> _regexCapture(String pattern, {required bool all}) {
    final out = <String>[];
    try {
      final re = RegExp(pattern, multiLine: true, dotAll: true);
      if (all) {
        for (final m in re.allMatches(_content)) {
          if (m.groupCount >= 1) {
            out.add(m.group(1) ?? '');
          } else {
            out.add(m.group(0) ?? '');
          }
        }
      } else {
        final m = re.firstMatch(_content);
        if (m != null) {
          for (var i = 0; i <= m.groupCount; i++) {
            out.add(m.group(i) ?? '');
          }
        }
      }
    } catch (_) {}
    return out.where((s) => s.isNotEmpty).toList();
  }

  String _runJs(String code) {
    final vars = variables.toJson();
    return js.evaluateRule(code, variables: vars, content: _content);
  }

  /// Expand {{...}} templates and @get:{key} before evaluation.
  String _makeUpRule(String rule) {
    var out = rule;
    // @get:{key}
    out = out.replaceAllMapped(RegExp(r'@get:\{([^}]+)\}'), (m) {
      return variables.get(m.group(1)!.trim()) ?? '';
    });
    // {{ ... }} — may contain nested braces but not triple-quoted strings here.
    out = _replaceTemplates(out);
    return out;
  }

  String _replaceTemplates(String input) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < input.length) {
      final start = input.indexOf('{{', i);
      if (start < 0) {
        buffer.write(input.substring(i));
        break;
      }
      buffer.write(input.substring(i, start));
      var depth = 2;
      var j = start + 2;
      while (j < input.length && depth > 0) {
        if (input.startsWith('{{', j)) {
          depth += 2;
          j += 2;
        } else if (input.startsWith('}}', j)) {
          depth -= 2;
          j += 2;
        } else {
          j++;
        }
      }
      if (depth > 0) {
        buffer.write(input.substring(start));
        break;
      }
      final expr = input.substring(start + 2, j - 2).trim();
      final result = js.evaluateRule(expr, variables: variables.toJson(), content: _content);
      buffer.write(result);
      i = j;
    }
    return buffer.toString();
  }

  static String _stripPrefix(String rule, String kind) {
    final prefixes = switch (kind) {
      'css' => const ['@css:', '@@'],
      'xpath' => const ['@XPath:', '@xpath:'],
      'json' => const ['@json:', '@JSON:'],
      _ => const <String>[],
    };
    for (final p in prefixes) {
      if (rule.startsWith(p)) return rule.substring(p.length).trim();
    }
    return rule;
  }

  static bool _looksLikeJs(String rule) {
    final r = rule.trimLeft();
    return r.startsWith('java.') ||
        r.startsWith('source.') ||
        r.startsWith('book.') ||
        r.startsWith('JSON.parse(') ||
        r.startsWith('String(') ||
        (r.contains(';') && (r.contains('result') || r.contains('return')));
  }

  static String _stringify(dynamic value) => value == null
      ? ''
      : value is List
          ? value.join(', ')
          : value.toString();

  static List<String> _splitTopLevel(String input, String sep) {
    final parts = <String>[];
    var depth = 0;
    var last = 0;
    var i = 0;
    while (i < input.length) {
      if (input.startsWith('{{', i)) {
        depth++;
        i += 2;
        continue;
      }
      if (input.startsWith('}}', i)) {
        depth--;
        i += 2;
        continue;
      }
      if (depth == 0 && input.startsWith(sep, i)) {
        parts.add(input.substring(last, i));
        i += sep.length;
        last = i;
        continue;
      }
      i++;
    }
    parts.add(input.substring(last));
    return parts;
  }

  static int _indexOfTopLevel(String input, String needle) {
    var depth = 0;
    var i = 0;
    while (i < input.length) {
      if (input.startsWith('{{', i)) {
        depth++;
        i += 2;
        continue;
      }
      if (input.startsWith('}}', i)) {
        depth--;
        i += 2;
        continue;
      }
      if (depth == 0 && input.startsWith(needle, i)) return i;
      i++;
    }
    return -1;
  }

  static List<String> _splitReplace(String after) {
    // ##pattern##replacement optionally followed by ##first
    final first = after.indexOf('##');
    if (first < 0) return const <String>[];
    final pattern = after.substring(0, first);
    final rest = after.substring(first + 2);
    final second = rest.indexOf('##');
    if (second < 0) return <String>[pattern, rest];
    return <String>[pattern, rest.substring(0, second), rest.substring(second + 2).trim()];
  }
}
