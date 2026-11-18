/// JavaScript rule execution backed by flutter_js (QuickJS on Android).
///
/// Injects the Legado JS environment: `result`, `source`, `book`, `key`, `page`,
/// plus a `java` compatibility shim for the most common helpers. One lazily
/// created runtime is reused for the whole app; `evaluateRule` serializes
/// access because QuickJS is not reentrant.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

class JsRuntime {
  JavascriptRuntime? _runtime;
  Completer<void>? _initializing;
  bool _enabled = true;

  JsRuntime({bool enabled = true}) : _enabled = enabled;

  bool get enabled => _enabled;

  Future<JavascriptRuntime?> _ensure() async {
    if (!_enabled) return null;
    if (_runtime != null) return _runtime;
    if (_initializing != null) {
      await _initializing!.future;
      return _runtime;
    }
    _initializing = Completer<void>();
    try {
      final runtime = getJavascriptRuntime(forceJavascriptCoreOnAndroid: false);
      _installShims(runtime);
      _runtime = runtime;
      _initializing!.complete();
    } catch (_) {
      _enabled = false;
      _initializing!.complete();
    }
    return _runtime;
  }

  void _installShims(JavascriptRuntime runtime) {
    // Minimal `java` shim. Sources mostly call java.t2s / java.log / java.get.
    runtime.evaluate('''
      var java = {
        log: function(){},
        t2s: function(s){ return s == null ? "" : String(s); },
        s2t: function(s){ return s == null ? "" : String(s); },
        get: function(k){ return (typeof __vars !== "undefined" && __vars[k]) || ""; },
        put: function(k,v){ if(typeof __vars !== "undefined"){ __vars[k]=v; } return v; },
        ajax: function(){ return ""; },
        find: function(str, regex){ var m = String(str).match(new RegExp(regex)); return m ? m[0] : ""; },
        base64Decode: function(s){ return s; }
      };
      var source = {};
      var book = {};
      var result = "";
    ''');
  }

  /// Run a JS rule and return its string result.
  /// [variables] are exposed directly and via `java.get`; [content] is the raw
  /// page body exposed as `source.content`.
  String evaluateRule(
    String code, {
    Map<String, dynamic> variables = const <String, dynamic>{},
    String content = '',
  }) {
    final runtime = _runtime;
    if (!_enabled || runtime == null || code.trim().isEmpty) {
      return _fallback(code, variables);
    }
    try {
      final varsJson = jsonEncode(variables);
      final contentJson = jsonEncode(content);
      final wrapped = '''
        (function(){
          var __vars = $varsJson;
          var result = "";
          var source = {content: $contentJson, url: (__vars.url || "")};
          var book = (__vars.book && typeof __vars.book === "object") ? __vars.book : {};
          var key = __vars["key"] || "";
          var page = __vars["page"] || 1;
          try {
            $code
          } catch(e) {}
          if (result == null) return "";
          if (typeof result === "string") return result;
          if (Array.isArray(result)) return result.join("\\n");
          return JSON.stringify(result);
        })()
      ''';
      final res = runtime.evaluate(wrapped);
      final value = res.stringResult?.trim() ?? '';
      if (value == 'undefined' || value == 'null') return '';
      return value;
    } catch (_) {
      return _fallback(code, variables);
    }
  }

  /// When the JS engine is unavailable, handle the handful of trivial
  /// expressions we can safely evaluate (string concatenation of variables).
  String _fallback(String code, Map<String, dynamic> variables) {
    var expr = code.trim();
    // "prefix" + key + "suffix" style concatenation.
    if (!expr.contains(';') && expr.contains('+')) {
      final parts = expr.split('+').map((p) {
        var token = p.trim();
        if (token.startsWith('"') && token.endsWith('"')) {
          return token.substring(1, token.length - 1);
        }
        if (token.startsWith("'") && token.endsWith("'")) {
          return token.substring(1, token.length - 1);
        }
        return variables[token]?.toString() ?? '';
      });
      return parts.join();
    }
    if (variables.containsKey(expr)) return variables[expr].toString();
    return '';
  }

  Future<void> warmUp() => _ensure();

  void dispose() {
    _enabled = false;
    _runtime = null;
  }
}
