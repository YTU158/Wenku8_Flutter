/// A pragmatic XPath evaluator for HTML scraping rules.
///
/// Legado sources overwhelmingly use a small XPath subset:
///   //tag  /tag  @attr  text()  [@attr='v']  [n]  [last()]  contains()
/// This engine operates on the `html` package DOM, supports absolute/relative
/// axes, predicates and the common string functions. It is intentionally not a
/// complete XPath 1.0 implementation — unsupported constructs degrade to an
/// empty result rather than throwing, so one bad rule cannot break a source.
import 'package:html/dom.dart' as dom;

class XPathResult {
  XPathResult.nodes(this.nodes) : text = null;
  XPathResult.text(this.text) : nodes = const [];
  XPathResult.attribute(this.text) : nodes = const [];

  final List<dom.Node> nodes;
  final String? text;

  bool get isEmpty => text == null && nodes.isEmpty;
  String get stringValue => text ?? nodes.map((n) => n.text ?? '').join('');
}

class XPathEngine {
  XPathEngine(this.document);

  final dom.Document document;

  XPathResult evaluate(String expression) {
    final expr = expression.trim();
    if (expr.isEmpty) return XPathResult.nodes(const []);
    try {
      final parser = _Parser(expr);
      final steps = parser.parse();
      final initial = document.documentElement == null
          ? <dom.Node>[]
          : <dom.Node>[document.documentElement!];
      final results = _evalSteps(steps, initial);
      final ending = parser.resultMode;
      if (ending is _ResultModeText) {
        return XPathResult.text(results.map((n) => n.text ?? '').join(' ').trim());
      }
      if (ending is _ResultModeAttribute) {
        final attr = ending.name;
        return XPathResult.attribute(
          results.map((n) => _attr(n, attr) ?? '').where((s) => s.isNotEmpty).join(' '),
        );
      }
      return XPathResult.nodes(List.unmodifiable(results));
    } catch (_) {
      return XPathResult.nodes(const []);
    }
  }

  List<dom.Node> select(String expression) => evaluate(expression).nodes;

  String selectString(String expression) => evaluate(expression).stringValue.trim();

  List<dom.Node> _evalSteps(List<_Step> steps, List<dom.Node> initial) {
    var current = initial;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final next = <dom.Node>[];
      if (step.axis == _Axis.self) {
        next.addAll(current);
      } else if (step.axis == _Axis.parent) {
        for (final n in current) {
          final p = n.parent;
          if (p != null && p is dom.Element) next.add(p);
        }
      } else {
        for (final node in current) {
          if (step.axis == _Axis.descendant) {
            next.addAll(_descendants(node, step));
          } else {
            next.addAll(_children(node, step));
          }
        }
      }
      final filtered = <dom.Node>[];
      for (final node in next) {
        if (_matchesPredicates(node, step.predicates)) filtered.add(node);
      }
      current = _dedupe(filtered);
    }
    return current;
  }

  List<dom.Node> _children(dom.Node node, _Step step) {
    final out = <dom.Node>[];
    for (final child in node.nodes) {
      if (child is dom.Element && _nameMatches(child.localName ?? '', step.name)) {
        out.add(child);
      }
    }
    return out;
  }

  List<dom.Node> _descendants(dom.Node node, _Step step) {
    final out = <dom.Node>[];
    void walk(dom.Node n) {
      for (final child in n.nodes) {
        if (child is dom.Element) {
          if (step.name == '*' || _nameMatches(child.localName ?? '', step.name)) {
            out.add(child);
          }
          walk(child);
        }
      }
    }
    walk(node);
    return out;
  }

  bool _matchesPredicates(dom.Node node, List<_Predicate> predicates) {
    for (final p in predicates) {
      switch (p.kind) {
        case _PredicateKind.idx:
          if (p.index == null || p.index! < 0) return false;
          final siblings = _siblingsMatching(node, p.siblingName);
          final target = p.fromLast ? siblings.length - 1 - p.index! : p.index!;
          if (target < 0 || target >= siblings.length || siblings[target] != node) {
            return false;
          }
          break;
        case _PredicateKind.attrEquals:
          if (_attr(node, p.name!) != p.value) return false;
          break;
        case _PredicateKind.attrContains:
          final v = _attr(node, p.name!) ?? '';
          if (p.value!.isEmpty ? v.isNotEmpty : !v.contains(p.value!)) return false;
          break;
        case _PredicateKind.hasAttr:
          if (_attr(node, p.name!) == null) return false;
          break;
        case _PredicateKind.textContains:
          final v = node.text ?? '';
          if (p.value!.isEmpty ? v.trim().isNotEmpty : !v.contains(p.value!)) return false;
          break;
      }
    }
    return true;
  }

  List<dom.Node> _siblingsMatching(dom.Node node, String? name) {
    final parent = node.parent;
    if (parent == null) return <dom.Node>[node];
    return parent.nodes
        .where((n) => n is dom.Element && (name == null || _nameMatches(n.localName ?? '', name)))
        .toList();
  }

  static bool _nameMatches(String actual, String wanted) =>
      wanted == '*' || actual.toLowerCase() == wanted.toLowerCase();

  static String? _attr(dom.Node node, String name) {
    if (node is dom.Element) {
      final direct = node.attributes[name];
      if (direct != null) return direct;
      final attrs = node.attributes;
      for (final key in attrs.keys) {
        final keyName = key.toString();
        if (keyName.toLowerCase() == name.toLowerCase()) return attrs[key];
      }
    }
    return null;
  }

  static List<dom.Node> _dedupe(Iterable<dom.Node> nodes) {
    final seen = <dom.Node>{};
    return nodes.where((n) => seen.add(n)).toList();
  }
}

enum _Axis { child, descendant, self, parent }

sealed class _ResultMode {}
class _ResultModeNodes extends _ResultMode {}
class _ResultModeText extends _ResultMode {}
class _ResultModeAttribute extends _ResultMode {
  _ResultModeAttribute(this.name);
  final String name;
}

class _Step {
  _Step({
    required this.axis,
    required this.name,
    this.predicates = const [],
  });
  final _Axis axis;
  final String name;
  final List<_Predicate> predicates;
}

enum _PredicateKind { idx, attrEquals, attrContains, hasAttr, textContains }

class _Predicate {
  _Predicate(this.kind, {this.index, this.name, this.value, this.fromLast = false, this.siblingName});
  final _PredicateKind kind;
  final int? index;
  final String? name;
  final String? value;
  final bool fromLast;
  final String? siblingName;
}

class _Parser {
  _Parser(this.source);
  final String source;
  int pos = 0;
  _ResultMode resultMode = _ResultModeNodes();

  List<_Step> parse() {
    final steps = <_Step>[];
    if (_peek() == '/') _advance();
    while (pos < source.length) {
      if (_peek() == '/') {
        _advance();
        if (_peek() == '/') {
          _advance();
        } else if (steps.isNotEmpty && _peek() == '@') {
          // trailing /@attr
        }
      }
      if (pos >= source.length) break;
      if (_peek() == '@') {
        _advance();
        final name = _readName();
        resultMode = _ResultModeAttribute(name);
        break;
      }
      if (source.startsWith('text()', pos)) {
        _advanceBy(6);
        resultMode = _ResultModeText();
        break;
      }
      if (_peek() == '.') {
        _advance();
        steps.add(_Step(axis: _Axis.self, name: '*'));
        continue;
      }
      if (_peek() == '*') {
        _advance();
        steps.add(_Step(axis: _Axis.child, name: '*', predicates: _parsePredicates()));
        continue;
      }
      final name = _readName();
      if (name.isEmpty) {
        _advance();
        continue;
      }
      if (name == 'text') {
        resultMode = _ResultModeText();
        break;
      }
      steps.add(_Step(axis: _Axis.child, name: name, predicates: _parsePredicates()));
      if (resultMode is! _ResultModeNodes) break;
    }
    // A `//tag` first step is a descendant-of-root search.
    if (source.startsWith('//') && steps.isNotEmpty) {
      steps[0] = _Step(axis: _Axis.descendant, name: steps[0].name, predicates: steps[0].predicates);
    }
    return steps;
  }

  List<_Predicate> _parsePredicates() {
    final result = <_Predicate>[];
    while (pos < source.length && _peek() == '[') {
      _advance();
      final inner = _readUntil(']');
      if (_peek() == ']') _advance();
      result.add(_parsePredicate(inner.trim()));
    }
    return result;
  }

  _Predicate _parsePredicate(String expr) {
    final lastRe = RegExp(r'^last\(\)\s*-\s*(\d+)$').firstMatch(expr);
    if (lastRe != null) {
      return _Predicate(_PredicateKind.idx,
          index: int.tryParse(lastRe.group(1) ?? '0') ?? 0, fromLast: true);
    }
    if (expr == 'last()') {
      return _Predicate(_PredicateKind.idx, index: 0, fromLast: true);
    }
    final indexRe = RegExp(r'^(\d+)$').firstMatch(expr);
    if (indexRe != null) {
      return _Predicate(_PredicateKind.idx,
          index: (int.tryParse(indexRe.group(1) ?? '1') ?? 1) - 1);
    }
    final containsRe = RegExp(
      r"""contains\(\s*@([\w\-:]+)\s*,\s*['"](.*)['"]\s*\)""",
      dotAll: true,
    ).firstMatch(expr);
    if (containsRe != null) {
      return _Predicate(_PredicateKind.attrContains,
          name: containsRe.group(1), value: containsRe.group(2));
    }
    final textContainsRe = RegExp(
      r"""contains\(\s*text\(\)\s*,\s*['"](.*)['"]\s*\)""",
      dotAll: true,
    ).firstMatch(expr);
    if (textContainsRe != null) {
      return _Predicate(_PredicateKind.textContains, value: textContainsRe.group(1));
    }
    final eqRe = RegExp(
      r"""^@([\w\-:]+)\s*=\s*['"](.*)['"]$""",
      dotAll: true,
    ).firstMatch(expr);
    if (eqRe != null) {
      return _Predicate(_PredicateKind.attrEquals,
          name: eqRe.group(1), value: eqRe.group(2));
    }
    final hasRe = RegExp(r'^@([\w\-:]+)$').firstMatch(expr);
    if (hasRe != null) {
      return _Predicate(_PredicateKind.hasAttr, name: hasRe.group(1));
    }
    return _Predicate(_PredicateKind.idx, index: -1);
  }

  String _readUntil(String ch) {
    final start = pos;
    while (pos < source.length && source[pos] != ch) pos++;
    return source.substring(start, pos);
  }

  String _readName() {
    final start = pos;
    while (pos < source.length) {
      final c = source[pos];
      if (_isNameChar(c)) {
        pos++;
      } else {
        break;
      }
    }
    return source.substring(start, pos);
  }

  static bool _isNameChar(String c) =>
      (c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90) ||
      (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122) ||
      (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) ||
      c == '_' || c == '-' || c == ':' || c == '.';

  String _peek() => pos < source.length ? source[pos] : '';
  void _advance() => pos++;
  void _advanceBy(int n) => pos += n;
}
