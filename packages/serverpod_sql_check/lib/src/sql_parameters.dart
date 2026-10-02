/// Parameter normalization for PostgreSQL with standard_conforming_strings on.
library;

final class NormalizedSql {
  const NormalizedSql(
    this.sql,
    this.offsets,
    this.namedOffsets,
    this.hasPositional,
  );

  final String sql;

  /// Original UTF-16 offset for every UTF-16 code unit in [sql].
  final List<int> offsets;
  final Map<String, int> namedOffsets;
  final bool hasPositional;
  bool get mixesParameters => namedOffsets.isNotEmpty && hasPositional;
}

final _named = RegExp(r'@[A-Za-z_][A-Za-z_0-9]*');
final _positional = RegExp(r'\$[0-9]+');
final _dollar = RegExp(
  r'\$(?:[A-Za-z_\u0080-\uffff][A-Za-z_0-9\u0080-\uffff]*)?\$',
);
bool _identifierStart(int code) =>
    code == 95 ||
    code >= 128 ||
    code >= 65 && code <= 90 ||
    code >= 97 && code <= 122;
bool _identifierPart(int code) =>
    _identifierStart(code) || code == 36 || code >= 48 && code <= 57;

NormalizedSql normalizeSqlParameters(String sql) {
  final output = StringBuffer();
  final offsets = <int>[];
  final namedOffsets = <String, int>{};
  final indexes = <String, int>{};
  var hasPositional = false;
  var i = 0;
  while (i < sql.length) {
    var end = i + 1;
    final escapeString =
        (sql[i] == 'E' || sql[i] == 'e') && end < sql.length && sql[end] == "'";
    if (sql.startsWith('--', i)) {
      end = sql.indexOf('\n', i + 2);
      if (end < 0) end = sql.length;
    } else if (sql.startsWith('/*', i)) {
      var depth = 1;
      end = i + 2;
      while (end < sql.length && depth > 0) {
        if (sql.startsWith('/*', end)) {
          depth++;
          end += 2;
        } else if (sql.startsWith('*/', end)) {
          depth--;
          end += 2;
        } else {
          end++;
        }
      }
    } else if (sql[i] == "'" || sql[i] == '"' || escapeString) {
      final quote = escapeString ? "'" : sql[i];
      if (escapeString) end++;
      while (end < sql.length) {
        if (escapeString && sql[end] == '\\') {
          end = (end + 2).clamp(0, sql.length);
        } else if (sql[end] == quote) {
          end++;
          if (end >= sql.length || sql[end] != quote) break;
          end++;
        } else {
          end++;
        }
      }
    } else if (_identifierStart(sql.codeUnitAt(i))) {
      // Dollar signs within unquoted identifiers are not parameters or quotes.
      while (end < sql.length && _identifierPart(sql.codeUnitAt(end))) {
        end++;
      }
    } else {
      final dollar = _dollar.matchAsPrefix(sql, i);
      if (dollar != null) {
        final close = sql.indexOf(dollar.group(0)!, dollar.end);
        end = close < 0 ? sql.length : close + dollar.group(0)!.length;
      } else {
        final positional = _positional.matchAsPrefix(sql, i);
        if (positional != null) {
          hasPositional = true;
          end = positional.end;
        }
        final parameter = _named.matchAsPrefix(sql, i);
        if (parameter != null) {
          final name = parameter.group(0)!.substring(1);
          namedOffsets.putIfAbsent(name, () => i);
          final index = indexes.putIfAbsent(name, () => indexes.length + 1);
          final placeholder = '\$$index';
          output.write(placeholder);
          offsets.addAll(List.filled(placeholder.length, i));
          i = parameter.end;
          continue;
        }
      }
    }
    output.write(sql.substring(i, end));
    offsets.addAll(List.generate(end - i, (offset) => i + offset));
    i = end;
  }
  return NormalizedSql(output.toString(), offsets, namedOffsets, hasPositional);
}
