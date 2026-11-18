/// A compact JSONPath evaluator covering the constructs used by Legado sources:
///   $.a.b   $[0]   $..name   $.a[*].b   $['key']   array slices
library;

class JsonPath {
  static List<dynamic> evaluate(dynamic root, String path) {
    var expr = path.trim();
    if (expr.startsWith('@json:')) expr = expr.substring(6);
    if (expr.startsWith('\$')) expr = expr.substring(1);
    if (expr.isEmpty) return <dynamic>[root];

    final tokens = _tokenize(expr);
    var current = <dynamic>[root];
    for (final token in tokens) {
      final next = <dynamic>[];
      for (final value in current) {
        next.addAll(_apply(value, token));
      }
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  static List<_Token> _tokenize(String expr) {
    final tokens = <_Token>[];
    var i = 0;
    while (i < expr.length) {
      if (expr[i] == '.') {
        i++;
        if (i < expr.length && expr[i] == '.') {
          i++;
          final name = _readName(expr, i);
          i += name.length;
          tokens.add(_Token(_TokenType.recursive, name));
        } else if (i < expr.length && expr[i] == '[') {
          // .[0] — treat as normal bracket below
          continue;
        } else {
          final name = _readName(expr, i);
          if (name.isNotEmpty) {
            tokens.add(_Token(_TokenType.child, name));
            i += name.length;
          }
        }
      } else if (expr[i] == '[') {
        final end = expr.indexOf(']', i);
        if (end < 0) break;
        final inner = expr.substring(i + 1, end).trim();
        i = end + 1;
        final slice = RegExp(r'^(\d*):(\d*)$').firstMatch(inner);
        if (slice != null) {
          tokens.add(_Token(
            _TokenType.slice,
            '',
            start: slice.group(1)!.isEmpty ? null : int.tryParse(slice.group(1)!),
            end: slice.group(2)!.isEmpty ? null : int.tryParse(slice.group(2)!),
          ));
        } else if (inner == '*') {
          tokens.add(const _Token(_TokenType.wildcard, ''));
        } else if ((inner.startsWith("'") && inner.endsWith("'")) ||
            (inner.startsWith('"') && inner.endsWith('"'))) {
          tokens.add(_Token(_TokenType.child, inner.substring(1, inner.length - 1)));
        } else {
          final idx = int.tryParse(inner);
          if (idx != null) tokens.add(_Token(_TokenType.idx, '', index: idx));
        }
      } else if (expr[i] == '*') {
        tokens.add(const _Token(_TokenType.wildcard, ''));
        i++;
      } else {
        final name = _readName(expr, i);
        if (name.isNotEmpty) {
          tokens.add(_Token(_TokenType.child, name));
          i += name.length;
        } else {
          i++;
        }
      }
    }
    return tokens;
  }

  static String _readName(String expr, int i) {
    final start = i;
    while (i < expr.length) {
      final c = expr[i];
      if (c == '.' || c == '[' || c == ']' || c == '*' || c == ':') break;
      i++;
    }
    return expr.substring(start, i);
  }

  static List<dynamic> _apply(dynamic value, _Token token) {
    switch (token.type) {
      case _TokenType.child:
        if (value is Map && value.containsKey(token.name)) return <dynamic>[value[token.name]];
        return const <dynamic>[];
      case _TokenType.idx:
        if (value is List) {
          final idx = token.index!;
          final real = idx < 0 ? value.length + idx : idx;
          if (real >= 0 && real < value.length) return <dynamic>[value[real]];
        }
        return const <dynamic>[];
      case _TokenType.slice:
        if (value is List) {
          final start = token.start ?? 0;
          final end = token.end ?? value.length;
          final from = start < 0 ? value.length + start : start;
          final to = end < 0 ? value.length + end : end;
          if (from < to && from < value.length) {
            return value.sublist(from, to > value.length ? value.length : to);
          }
        }
        return const <dynamic>[];
      case _TokenType.wildcard:
        if (value is List) return List<dynamic>.from(value);
        if (value is Map) return value.values.toList();
        return const <dynamic>[];
      case _TokenType.recursive:
        return _descend(value, token.name);
    }
  }

  static List<dynamic> _descend(dynamic value, String name) {
    final out = <dynamic>[];
    void walk(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          if (name == '*' || entry.key == name) out.add(entry.value);
          walk(entry.value);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }
    walk(value);
    return out;
  }
}

enum _TokenType { child, idx, slice, wildcard, recursive }

class _Token {
  const _Token(this.type, this.name, {this.index, this.start, this.end});
  final _TokenType type;
  final String name;
  final int? index;
  final int? start;
  final int? end;
}
