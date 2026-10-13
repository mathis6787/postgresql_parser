/// Prepares a limited psql script for syntax validation, without executing it.
library;

final class PreparedPsql {
  const PreparedPsql(this.sql, this.gexecOffsets, {this.unsupported});

  /// Same-length SQL, with standalone \gexec lines replaced by semicolons.
  /// Original UTF-16 offsets and line breaks are preserved.
  final String sql;
  final List<int> gexecOffsets;
  final String? unsupported;
}

final _dollarQuote = RegExp(
  r'\$(?:[A-Za-z_\u0080-\uffff][A-Za-z_0-9\u0080-\uffff]*)?\$',
);

bool _identifierStart(int code) =>
    code == 95 ||
    code >= 128 ||
    code >= 65 && code <= 90 ||
    code >= 97 && code <= 122;
bool _identifierPart(int code) =>
    _identifierStart(code) || code == 36 || code >= 48 && code <= 57;

/// A standalone unquoted \gexec identifies a psql script. Other backslash
/// commands require client semantics that this checker does not implement.
/// Callers must not use this for queries sent directly to a database driver.
PreparedPsql preparePsqlScript(String sql) {
  final gexecOffsets = <int>[];
  List<int>? output;
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
      // A dollar sign inside an unquoted identifier is not a dollar quote.
      while (end < sql.length && _identifierPart(sql.codeUnitAt(end))) {
        end++;
      }
    } else if (sql[i] == '\\') {
      var lineEnd = sql.indexOf('\n', i);
      if (lineEnd < 0) lineEnd = sql.length;
      final lineStart = sql.lastIndexOf('\n', i) + 1;
      final command = sql.substring(i, lineEnd).trimRight();
      if (command != r'\gexec' ||
          sql.substring(lineStart, i).trim().isNotEmpty) {
        final name = command.split(RegExp(r'\s')).first;
        return PreparedPsql(
          sql,
          const [],
          unsupported:
              'unsupported psql command $name '
              '(only standalone \\gexec without arguments is supported)',
        );
      }
      output ??= sql.codeUnits.toList();
      output[i] = 59; // ; terminates the current query buffer for parsing only.
      for (var offset = i + 1; offset < i + command.length; offset++) {
        output[offset] = 32;
      }
      gexecOffsets.add(i);
      end = lineEnd;
    } else {
      final dollar = _dollarQuote.matchAsPrefix(sql, i);
      if (dollar != null) {
        final close = sql.indexOf(dollar.group(0)!, dollar.end);
        end = close < 0 ? sql.length : close + dollar.group(0)!.length;
      }
    }
    i = end;
  }
  return PreparedPsql(
    output == null ? sql : String.fromCharCodes(output),
    gexecOffsets,
  );
}
