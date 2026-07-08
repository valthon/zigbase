/// Client-side filter parser, evaluator, and analyzer for the live store.
///
/// A byte-for-byte behavioral port of
/// `clients/typescript/src/live/filter-eval.ts`. The grammar mirrors the
/// server's filter lexer for the subset the client can evaluate locally:
///
///  - comparison operators: `=` `!=` `>` `>=` `<` `<=` `~` `!~`
///  - boolean logic: `&&`, `||`, parentheses (`||` binds loosest, then `&&`,
///    then comparisons / parens)
///  - literals: single- OR double-quoted strings (with `\\`/`\'`/`\"` escapes),
///    numbers, `true`/`false`/`null`
///  - dotted field paths (`author.name`) and field-to-field comparisons
///    (`@request.auth.id = owner`)
///
/// [analyzeFilter] classifies whether a filter is **locally evaluable** — it is
/// iff it references no relation traversal (a dotted path) and no `@`-macro. A
/// non-locally-evaluable filter drives the live list into its refetch tier.
library;

// ---- AST -------------------------------------------------------------------

/// Base type of a parsed filter node. Either a [CompareNode] or a [LogicNode].
sealed class FilterNode {
  const FilterNode();
}

/// A `path op value` (or `path op valuePath`) comparison.
class CompareNode extends FilterNode {
  final List<String> path;

  /// One of `=` `!=` `>` `>=` `<` `<=` `~` `!~`.
  final String op;

  /// The right-hand literal (`String` / `num` / `bool` / `null`). Unused when
  /// [valuePath] is set.
  final Object? value;

  /// A field-path right-hand operand (e.g. `@request.auth.id = owner`), if any.
  /// When present, [value] is unused and membership is NOT locally evaluable.
  final List<String>? valuePath;

  const CompareNode(this.path, this.op, this.value, {this.valuePath});
}

/// A `left && right` or `left || right` node.
class LogicNode extends FilterNode {
  /// `'and'` or `'or'`.
  final String kind;
  final FilterNode left;
  final FilterNode right;

  const LogicNode(this.kind, this.left, this.right);
}

// ---- tokenizer -------------------------------------------------------------

enum _TokKind { field, op, and, or, lparen, rparen, lit }

class _Token {
  final _TokKind kind;

  /// `String` for `field`/`op`; the literal (`String`/`num`/`bool`/`null`) for
  /// `lit`; `null` for the punctuation tokens.
  final Object? value;

  const _Token(this.kind, [this.value]);
}

const _opChars = {'=', '!', '>', '<', '~'};
const _wordStops = ' \t\n()&|=!<>~\'"';
final RegExp _numberPattern = RegExp(r'^-?\d+(\.\d+)?$');

List<_Token> _tokenize(String input) {
  final tokens = <_Token>[];
  var i = 0;
  final n = input.length;
  while (i < n) {
    final c = input[i];
    if (c == ' ' || c == '\t' || c == '\n') {
      i += 1;
      continue;
    }
    if (c == '(') {
      tokens.add(const _Token(_TokKind.lparen));
      i += 1;
      continue;
    }
    if (c == ')') {
      tokens.add(const _Token(_TokKind.rparen));
      i += 1;
      continue;
    }
    if (c == '&' && i + 1 < n && input[i + 1] == '&') {
      tokens.add(const _Token(_TokKind.and));
      i += 2;
      continue;
    }
    if (c == '|' && i + 1 < n && input[i + 1] == '|') {
      tokens.add(const _Token(_TokKind.or));
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final quote = c;
      var j = i + 1;
      final buf = StringBuffer();
      while (j < n && input[j] != quote) {
        if (input[j] == r'\' && j + 1 < n) {
          buf.write(input[j + 1]);
          j += 2;
        } else {
          buf.write(input[j]);
          j += 1;
        }
      }
      tokens.add(_Token(_TokKind.lit, buf.toString()));
      i = j + 1;
      continue;
    }
    if (_opChars.contains(c)) {
      // Longest-match the operators.
      final two = i + 2 <= n ? input.substring(i, i + 2) : '';
      if (two == '!=' || two == '>=' || two == '<=' || two == '!~') {
        tokens.add(_Token(_TokKind.op, two));
        i += 2;
        continue;
      }
      if (c == '=' || c == '>' || c == '<' || c == '~') {
        tokens.add(_Token(_TokKind.op, c));
        i += 1;
        continue;
      }
      throw FormatException('unexpected operator near "${input.substring(i)}"');
    }
    // bareword: number, bool, null, or a (dotted) field path.
    var j = i;
    while (j < n && !_wordStops.contains(input[j])) {
      j += 1;
    }
    final word = input.substring(i, j);
    i = j;
    if (word == 'true') {
      tokens.add(const _Token(_TokKind.lit, true));
    } else if (word == 'false') {
      tokens.add(const _Token(_TokKind.lit, false));
    } else if (word == 'null') {
      tokens.add(const _Token(_TokKind.lit, null));
    } else if (_numberPattern.hasMatch(word)) {
      tokens.add(_Token(_TokKind.lit, num.parse(word)));
    } else {
      tokens.add(_Token(_TokKind.field, word));
    }
  }
  return tokens;
}

// ---- parser (precedence: || lowest, then &&, then comparisons / parens) -----

class _Parser {
  final List<_Token> tokens;
  int pos = 0;

  _Parser(this.tokens);

  FilterNode parse() {
    final node = _parseOr();
    if (pos != tokens.length) {
      throw const FormatException('trailing tokens in filter');
    }
    return node;
  }

  _Token? _peek() => pos < tokens.length ? tokens[pos] : null;

  _Token _next() {
    if (pos >= tokens.length) {
      throw const FormatException('unexpected end of filter');
    }
    return tokens[pos++];
  }

  FilterNode _parseOr() {
    var left = _parseAnd();
    while (_peek()?.kind == _TokKind.or) {
      _next();
      left = LogicNode('or', left, _parseAnd());
    }
    return left;
  }

  FilterNode _parseAnd() {
    var left = _parsePrimary();
    while (_peek()?.kind == _TokKind.and) {
      _next();
      left = LogicNode('and', left, _parsePrimary());
    }
    return left;
  }

  FilterNode _parsePrimary() {
    if (_peek()?.kind == _TokKind.lparen) {
      _next();
      final node = _parseOr();
      final close = _next();
      if (close.kind != _TokKind.rparen) {
        throw const FormatException('expected )');
      }
      return node;
    }
    return _parseCompare();
  }

  CompareNode _parseCompare() {
    final field = _next();
    if (field.kind != _TokKind.field) {
      throw const FormatException('expected a field path');
    }
    final op = _next();
    if (op.kind != _TokKind.op) {
      throw const FormatException('expected a comparison operator');
    }
    final rhs = _next();
    final path = (field.value! as String).split('.');
    if (rhs.kind == _TokKind.lit) {
      return CompareNode(path, op.value! as String, rhs.value);
    }
    if (rhs.kind == _TokKind.field) {
      // Field-to-field comparison (e.g. a macro like `@request.auth.id = owner`).
      // Not locally evaluable; carry the RHS path so analyzeFilter classifies it.
      return CompareNode(path, op.value! as String, null,
          valuePath: (rhs.value! as String).split('.'));
    }
    throw const FormatException('expected a literal value or field path');
  }
}

/// Parses a ZigBase filter [input] into a [FilterNode] AST. Throws a
/// [FormatException] on a malformed expression.
FilterNode parseFilter(String input) => _Parser(_tokenize(input)).parse();

// ---- evaluator -------------------------------------------------------------

Object? _resolvePath(Map<String, dynamic> record, List<String> path) {
  Object? cur = record;
  for (final key in path) {
    if (cur is! Map) return null;
    cur = cur[key];
  }
  return cur;
}

bool _compare(Object? actual, String op, Object? expected) {
  switch (op) {
    case '=':
      return actual == expected;
    case '!=':
      return actual != expected;
    case '>':
      return (actual as num) > (expected as num);
    case '>=':
      return (actual as num) >= (expected as num);
    case '<':
      return (actual as num) < (expected as num);
    case '<=':
      return (actual as num) <= (expected as num);
    case '~':
      return actual is String && actual.contains(expected.toString());
    case '!~':
      return !(actual is String && actual.contains(expected.toString()));
    default:
      throw FormatException('unknown operator "$op"');
  }
}

/// Evaluates [node] against a [record] map. Only meaningful for a locally
/// evaluable filter (see [analyzeFilter]); a relation/macro node's [value] is
/// null and will not match a real field.
bool evaluateFilter(Map<String, dynamic> record, FilterNode node) {
  switch (node) {
    case CompareNode():
      return _compare(_resolvePath(record, node.path), node.op, node.value);
    case LogicNode(kind: 'and'):
      return evaluateFilter(record, node.left) &&
          evaluateFilter(record, node.right);
    case LogicNode():
      return evaluateFilter(record, node.left) ||
          evaluateFilter(record, node.right);
  }
}

// ---- analysis (tiered-correctness classification) --------------------------

/// The result of [analyzeFilter]: whether a filter can be decided precisely
/// from a record's own scalar fields, and why not if it can't.
class FilterAnalysis {
  /// True when membership can be decided precisely from a record's own scalar
  /// fields (no relation traversal, no macros).
  final bool locallyEvaluable;
  final bool referencesRelations;
  final bool referencesMacros;

  const FilterAnalysis({
    required this.locallyEvaluable,
    required this.referencesRelations,
    required this.referencesMacros,
  });
}

bool _isMacroPath(List<String> path) =>
    path.isNotEmpty && path[0].startsWith('@');

bool _isRelationPath(List<String> path) => path.length > 1;

/// Classifies a (possibly null) filter AST for the tiered-correctness decision.
/// A null filter matches all records and is trivially locally evaluable.
FilterAnalysis analyzeFilter(FilterNode? node) {
  if (node == null) {
    return const FilterAnalysis(
      locallyEvaluable: true,
      referencesRelations: false,
      referencesMacros: false,
    );
  }
  var referencesRelations = false;
  var referencesMacros = false;

  void classify(List<String> path) {
    if (_isMacroPath(path)) {
      referencesMacros = true;
    } else if (_isRelationPath(path)) {
      referencesRelations = true;
    }
  }

  void walk(FilterNode n) {
    switch (n) {
      case CompareNode():
        classify(n.path);
        final vp = n.valuePath;
        if (vp != null) classify(vp);
      case LogicNode():
        walk(n.left);
        walk(n.right);
    }
  }

  walk(node);

  return FilterAnalysis(
    locallyEvaluable: !referencesRelations && !referencesMacros,
    referencesRelations: referencesRelations,
    referencesMacros: referencesMacros,
  );
}
