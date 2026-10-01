/// Checks SQL with the local postgresql_parser package, without executing it.
library;

import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:serverpod_sql_check/src/string_references.dart';
import 'package:postgresql_parser/postgresql_parser.dart';

final _sqlStart = RegExp(
  r'^\s*(?:(?:--[^\n]*\n|/\*[\s\S]*?\*/)\s*)*(?:WITH|SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|DO|TRUNCATE|GRANT|REVOKE|COMMENT|REFRESH|VACUUM|ANALYZE|REINDEX|BEGIN|COMMIT|ROLLBACK|SET|RESET|CALL|EXPLAIN)\s+',
);
final _parameter = RegExp(r'@[A-Za-z_][A-Za-z_0-9]*');
final _dollarQuote = RegExp(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$');
const _rawMethods = {'unsafeQuery', 'unsafeExecute'};

/// Checks SQL and bindings, prints diagnostics, and sets [exitCode] on failure.
void checkSql(List<String> args) {
  var includeMigrations = false;
  var verbose = false;
  var major = 17;
  var root = Directory.current.path;
  final paths = <String>[];
  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      stdout.writeln(
        'Usage: dart run serverpod_sql_check [options] [file or directory ...]\n'
        '  --include-migrations    Include migration SQL (excluded by default)\n'
        '  --postgres-version=17   PostgreSQL grammar: 17 (default) or 18\n'
        '  --verbose               Print checked and skipped query locations\n'
        '  --root=<directory>      Project to scan by default (current directory)\n'
        'With no paths, scan the server directory. Dynamic SQL is reported as skipped.\n'
        'Named parameter bindings are checked when map keys are statically readable.',
      );
      return;
    } else if (arg == '--include-migrations') {
      includeMigrations = true;
    } else if (arg == '--verbose') {
      verbose = true;
    } else if (arg.startsWith('--postgres-version=')) {
      major = int.tryParse(arg.split('=').last) ?? -1;
    } else if (arg.startsWith('--root=')) {
      root = arg.substring('--root='.length);
    } else if (arg.startsWith('-')) {
      stderr.writeln('Unknown option: $arg. Use --help.');
      exitCode = 2;
      return;
    } else {
      paths.add(arg);
    }
  }
  final versions = PostgresParser.supportedVersions.where(
    (v) => v.major == major,
  );
  if (versions.isEmpty) {
    stderr.writeln(
      'Unsupported PostgreSQL version: $major. Supported: '
      '${PostgresParser.supportedVersions.map((v) => v.major).join(', ')}',
    );
    exitCode = 2;
    return;
  }
  final parser = PostgresParser(version: versions.single);
  final files = <String, File>{};
  var operationalErrors = 0;
  for (final path in paths.isEmpty ? [root] : paths) {
    try {
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
        throw FileSystemException('Path does not exist', path);
      }
      for (final file in _files(path, includeMigrations)) {
        files[file.absolute.path] = file;
      }
    } on FileSystemException catch (error) {
      stderr.writeln('ERROR: $error');
      operationalErrors++;
    }
  }
  var checked = 0;
  var failed = 0;
  var skipped = 0;
  var bindingsChecked = 0;
  var bindingFailures = 0;
  var bindingsSkipped = 0;
  var sqlFiles = 0;
  var dartFiles = 0;
  final sortedFiles = files.values.toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  stdout.writeln(
    'Using local postgresql_parser with PostgreSQL $major grammar.',
  );
  for (final file in sortedFiles) {
    try {
      final source = file.readAsStringSync();
      final isSql = file.path.endsWith('.sql');
      if (isSql) {
        sqlFiles++;
      } else {
        dartFiles++;
      }
      final blocks = isSql
          ? [
              _Block(0, [_SqlText.original(source)]),
            ]
          : _dartSql(source);
      for (final block in blocks) {
        final line =
            '\n'.allMatches(source.substring(0, block.offset)).length + 1;
        final label = '${_displayPath(file.absolute.path, root)}:$line';
        if (block.variants == null) {
          skipped++;
          if (verbose) stdout.writeln('SKIP $label (${block.reason})');
          continue;
        }
        for (var variant = 0; variant < block.variants!.length; variant++) {
          final text = block.variants![variant];
          if (text.text.trim().isEmpty) continue;
          final parameterOffsets = <String, int>{};
          final prepared = isSql
              ? text
              : _normalizeParameters(text, parameterOffsets: parameterOffsets);
          final sql = prepared.text;
          final variantLabel = block.variants!.length == 1
              ? label
              : '$label (variant ${variant + 1})';
          var missingBindings = false;
          final bindings = block.bindings;
          if (bindings != null && parameterOffsets.isNotEmpty) {
            final keys = bindings.keys;
            if (keys == null) {
              bindingsSkipped++;
              if (verbose) {
                stdout.writeln(
                  'SKIP BINDINGS $variantLabel (parameter map keys are not statically readable)',
                );
              }
            } else {
              bindingsChecked++;
              final available = keys.isEmpty
                  ? '<none>'
                  : (keys.toList()..sort()).join(', ');
              for (final parameter in parameterOffsets.entries) {
                if (keys.contains(parameter.key)) continue;
                missingBindings = true;
                bindingFailures++;
                _reportSqlFailure(
                  _displayPath(file.absolute.path, root),
                  source,
                  block.offset,
                  text,
                  parameter.value,
                  'missing named parameter binding for @${parameter.key} '
                  '(available keys: $available)',
                  block.variants!.length > 1 ? ' (variant ${variant + 1})' : '',
                );
              }
            }
          }
          checked++;
          try {
            parser.parse(sql);
            if (verbose && !missingBindings) stdout.writeln('OK $variantLabel');
          } on PostgresParseException catch (error) {
            // CTE helpers deliberately contain only a WITH clause. Complete that
            // fragment to validate its grammar; raw calls require a full query.
            if (!isSql &&
                !block.isRawQuery &&
                RegExp(r'^\s*WITH\b').hasMatch(sql) &&
                error.message == 'syntax error at end of input') {
              try {
                parser.parse('$sql\nSELECT 1;');
                if (verbose) stdout.writeln('OK $variantLabel (CTE fragment)');
                continue;
              } on PostgresParseException {
                // Report the original error when it is not a valid CTE prefix.
              }
            }
            failed++;
            _reportFailure(
              _displayPath(file.absolute.path, root),
              source,
              block.offset,
              prepared,
              error,
              block.variants!.length > 1 ? ' (variant ${variant + 1})' : '',
            );
          }
        }
      }
    } on FileSystemException catch (error) {
      stderr.writeln('ERROR: $error');
      operationalErrors++;
    }
  }
  stdout.writeln(
    'Scanned $sqlFiles SQL files and $dartFiles Dart files.\n'
    'Checked $checked SQL variants; $failed failed; $skipped dynamic queries/templates skipped.\n'
    'Checked $bindingsChecked named parameter sets; $bindingFailures missing bindings; '
    '$bindingsSkipped binding checks skipped.',
  );
  if ((skipped > 0 || bindingsSkipped > 0) && !verbose) {
    stdout.writeln(
      'Use --verbose to see skipped SQL and binding checks. Runtime-built SQL or parameter maps need a runtime check.',
    );
  }
  if (operationalErrors > 0) {
    exitCode = 2;
  } else if (failed > 0 || bindingFailures > 0) {
    exitCode = 1;
  }
}

String _displayPath(String path, String root) {
  final prefix = '${Directory(root).absolute.path}${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

Iterable<File> _files(String path, bool includeMigrations) sync* {
  final entityType = FileSystemEntity.typeSync(path, followLinks: false);
  final parts = File(path).absolute.uri.pathSegments;
  if (!includeMigrations &&
      parts.any((p) => p == 'migrations' || p == 'migration')) {
    return;
  }
  if (entityType == FileSystemEntityType.directory) {
    final name = Directory(path).absolute.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .last;
    if ({
      '.git',
      '.dart_tool',
      'build',
      'node_modules',
      'sql_check',
      'serverpod_sql_check',
    }.contains(name)) {
      return;
    }
    for (final child in Directory(path).listSync(followLinks: false)) {
      yield* _files(child.path, includeMigrations);
    }
  } else if (entityType == FileSystemEntityType.file) {
    final isSql = path.endsWith('.sql');
    final isDart =
        path.endsWith('.dart') &&
        !parts.contains('generated') &&
        !path.endsWith('.g.dart') &&
        !path.endsWith('.freezed.dart') &&
        !path.endsWith('${Platform.pathSeparator}check_sql.dart');
    if (isSql || isDart) yield File(path);
  }
}

final class _Block {
  _Block(this.offset, this.variants, {this.isRawQuery = false, this.bindings});
  final int offset;
  final List<_SqlText>? variants;
  final String reason = 'unresolved string reference or runtime SQL expression';
  final bool isRawQuery;
  final _NamedBindings? bindings;
}

List<_Block> _dartSql(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final finder = _RawQueryFinder();
  parsed.unit.accept(finder);
  final references = StringReferences(parsed.unit);
  final visitor = _SqlVisitor(finder.found, source, references);
  parsed.unit.accept(visitor);
  return visitor.blocks.values.toList()
    ..sort((a, b) => a.offset.compareTo(b.offset));
}

final class _RawQueryFinder extends RecursiveAstVisitor<void> {
  bool found = false;
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_rawMethods.contains(node.methodName.name)) found = true;
    super.visitMethodInvocation(node);
  }
}

final class _SqlVisitor extends RecursiveAstVisitor<void> {
  _SqlVisitor(this.hasRawCalls, this.source, this.references);
  final bool hasRawCalls;
  final String source;
  final StringReferences references;
  final blocks = <int, _Block>{};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_rawMethods.contains(node.methodName.name) &&
        node.argumentList.arguments.isNotEmpty) {
      final argument = node.argumentList.arguments.first.argumentExpression;
      Expression? parameters;
      for (final argument in node.argumentList.arguments) {
        if (argument is NamedArgument && argument.name.lexeme == 'parameters') {
          parameters = argument.argumentExpression;
        }
      }
      _add(
        argument,
        force: true,
        bindings: _namedBindings(parameters, source, references),
      );
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.lexeme == '+' && _sqlStart.hasMatch(_prefix(node))) {
      _add(node);
    } else {
      super.visitBinaryExpression(node);
    }
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => _add(node);

  @override
  void visitStringInterpolation(StringInterpolation node) => _add(node);

  @override
  void visitAdjacentStrings(AdjacentStrings node) => _add(node);

  void _add(Expression node, {bool force = false, _NamedBindings? bindings}) {
    if (!force) {
      for (
        AstNode? parent = node.parent;
        parent != null;
        parent = parent.parent
      ) {
        if (parent is StringInterpolation || parent is AdjacentStrings) return;
      }
    }
    final variants = _variants(node, source, references);
    final prefix = variants?.firstOrNull?.text ?? _prefix(node);
    if (force ||
        (_sqlStart.hasMatch(prefix) &&
            (hasRawCalls || _templateContext(node)))) {
      blocks[node.offset] = _Block(
        node.offset,
        variants,
        isRawQuery: force || (blocks[node.offset]?.isRawQuery ?? false),
        bindings: bindings ?? blocks[node.offset]?.bindings,
      );
    }
  }
}

// Only keys matter: map values may be arbitrary runtime expressions. A spread,
// conditional entry, or unknown key can supply any name, so skip the whole map.
final class _NamedBindings {
  _NamedBindings(this.keys);
  final Set<String>? keys;
}

_NamedBindings _namedBindings(
  Expression? expression,
  String source,
  StringReferences references,
) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  if (expression == null || expression is NullLiteral) {
    return _NamedBindings({});
  }
  ArgumentList? arguments;
  if (expression is InstanceCreationExpression) {
    // Before resolution, `new QueryParameters.named` can look like an import
    // prefix and a type called `named`, rather than a named constructor.
    final name = expression.constructorName.toSource();
    if (name == 'QueryParameters.named' ||
        name.endsWith('.QueryParameters.named')) {
      arguments = expression.argumentList;
    }
  } else if (expression is MethodInvocation &&
      expression.methodName.name == 'named') {
    final target = expression.target;
    if ((target is SimpleIdentifier && target.name == 'QueryParameters') ||
        (target is PrefixedIdentifier &&
            target.identifier.name == 'QueryParameters')) {
      arguments = expression.argumentList;
    }
  }
  if (arguments == null || arguments.arguments.length != 1) {
    return _NamedBindings(null);
  }
  var map = arguments.arguments.single.argumentExpression;
  while (map is ParenthesizedExpression) {
    map = map.expression;
  }
  if (map is! SetOrMapLiteral) return _NamedBindings(null);
  final keys = <String>{};
  for (final entry in map.elements) {
    if (entry is! MapLiteralEntry) return _NamedBindings(null);
    final variants = _variants(entry.key, source, references);
    if (variants == null || variants.length != 1) return _NamedBindings(null);
    keys.add(variants.single.text);
  }
  return _NamedBindings(keys);
}

bool _templateContext(AstNode node) {
  final sqlName = RegExp(r'sql|cte|query', caseSensitive: false);
  for (AstNode? parent = node.parent; parent != null; parent = parent.parent) {
    if (parent is VariableDeclaration) {
      return sqlName.hasMatch(parent.name.lexeme);
    }
    if (parent is NamedArgument) return sqlName.hasMatch(parent.name.lexeme);
    if (parent is MethodDeclaration) {
      return sqlName.hasMatch(parent.name.lexeme);
    }
    if (parent is FunctionDeclaration) {
      return sqlName.hasMatch(parent.name.lexeme);
    }
  }
  return false;
}

String _prefix(Expression node) {
  if (node is SimpleStringLiteral) return node.value;
  if (node is BinaryExpression) return _prefix(node.leftOperand);
  if (node is ParenthesizedExpression) return _prefix(node.expression);
  if (node is StringInterpolation) {
    final first = node.elements.firstOrNull;
    return first is InterpolationString ? first.value : '';
  }
  if (node is AdjacentStrings) return _prefix(node.strings.first);
  return '';
}

List<_SqlText>? _variants(
  Expression expression,
  String source,
  StringReferences references, [
  Set<VariableDeclaration>? active,
]) {
  active ??= {};
  if (expression is SimpleIdentifier ||
      expression is PrefixedIdentifier ||
      expression is PropertyAccess) {
    final declaration = references.declarationFor(expression);
    if (declaration == null || !active.add(declaration)) return null;
    try {
      return _variants(declaration.initializer!, source, references, active);
    } finally {
      active.remove(declaration);
    }
  }
  if (expression is SimpleStringLiteral) {
    return [
      _mappedValue(
        expression.value,
        source,
        expression.contentsOffset,
        expression.contentsEnd,
        expression.isRaw,
      ),
    ];
  }
  if (expression is ParenthesizedExpression) {
    return _variants(expression.expression, source, references, active);
  }
  if (expression is ConditionalExpression) {
    final yes = _variants(
      expression.thenExpression,
      source,
      references,
      active,
    );
    final no = _variants(expression.elseExpression, source, references, active);
    return yes == null || no == null ? null : _unique([...yes, ...no]);
  }
  if (expression is BinaryExpression && expression.operator.lexeme == '+') {
    return _combine(
      _variants(expression.leftOperand, source, references, active),
      _variants(expression.rightOperand, source, references, active),
    );
  }
  if (expression is AdjacentStrings) {
    List<_SqlText>? result = [_SqlText('', [], expression.offset)];
    for (final string in expression.strings) {
      result = _combine(result, _variants(string, source, references, active));
    }
    return result;
  }
  if (expression is StringInterpolation) {
    List<_SqlText>? result = [_SqlText('', [], expression.offset)];
    for (final element in expression.elements) {
      final values = element is InterpolationString
          ? [
              _mappedValue(
                element.value,
                source,
                element.contentsOffset,
                element.contentsEnd,
                false,
              ),
            ]
          : _variants(
              (element as InterpolationExpression).expression,
              source,
              references,
              active,
            );
      result = _combine(result, values);
    }
    return result;
  }
  return null;
}

List<_SqlText> _unique(Iterable<_SqlText> variants) {
  final result = <String, _SqlText>{};
  for (final value in variants) {
    result.putIfAbsent(value.text, () => value);
  }
  return result.values.toList();
}

List<_SqlText>? _combine(List<_SqlText>? left, List<_SqlText>? right) {
  if (left == null || right == null || left.length * right.length > 32) {
    return null;
  }
  return _unique([
    for (final a in left)
      for (final b in right)
        _SqlText(
          '${a.text}${b.text}',
          a.offsets == null || b.offsets == null
              ? null
              : [...a.offsets!, ...b.offsets!],
          b.endOffset,
        ),
  ]);
}

// Each decoded SQL code unit keeps its original Dart source offset. This map
// survives escapes, branch expansion, concatenation, and parameter rewriting.
final class _SqlText {
  _SqlText(this.text, this.offsets, this.endOffset);
  factory _SqlText.original(String source) =>
      _SqlText(source, List.generate(source.length, (i) => i), source.length);
  final String text;
  final List<int>? offsets;
  final int endOffset;
}

_SqlText _mappedValue(
  String value,
  String source,
  int start,
  int end,
  bool raw,
) {
  final decoded = StringBuffer();
  final offsets = <int>[];
  var i = start;
  const escapes = {
    'n': '\n',
    'r': '\r',
    't': '\t',
    'b': '\b',
    'f': '\f',
    'v': '\v',
  };
  while (i < end) {
    final origin = i;
    var character = source[i++];
    if (!raw && character == r'\' && i < end) {
      final escaped = source[i++];
      if (escaped == 'u' || escaped == 'x') {
        final braced = escaped == 'u' && i < end && source[i] == '{';
        if (braced) i++;
        final digitsStart = i;
        final digitsEnd = braced
            ? source.indexOf('}', i)
            : i + (escaped == 'x' ? 2 : 4);
        if (digitsEnd < digitsStart || digitsEnd > end) {
          return _SqlText(value, null, end);
        }
        final rune = int.tryParse(
          source.substring(digitsStart, digitsEnd),
          radix: 16,
        );
        if (rune == null || rune > 0x10ffff) return _SqlText(value, null, end);
        character = String.fromCharCode(rune);
        i = digitsEnd + (braced ? 1 : 0);
      } else {
        character = escapes[escaped] ?? escaped;
      }
    }
    decoded.write(character);
    offsets.addAll(List.filled(character.length, origin));
  }
  // Analyzer remains authoritative about Dart decoding. If a source form is
  // unsupported here, report the block location explicitly instead of guessing.
  return _SqlText(value, decoded.toString() == value ? offsets : null, end);
}

void _reportFailure(
  String path,
  String source,
  int blockOffset,
  _SqlText sql,
  PostgresParseException error,
  String variant,
) {
  final sqlOffset = error.cursorPosition > 0
      ? String.fromCharCodes(sql.text.runes.take(error.cursorPosition - 1))
            .length
      : null;
  _reportSqlFailure(
    path,
    source,
    blockOffset,
    sql,
    sqlOffset,
    error.message,
    variant,
  );
}

void _reportSqlFailure(
  String path,
  String source,
  int blockOffset,
  _SqlText sql,
  int? sqlOffset,
  String message,
  String variant,
) {
  final hasCursor = sqlOffset != null;
  final prefix = hasCursor ? sql.text.substring(0, sqlOffset) : '';
  final exact = hasCursor && sql.offsets != null;
  final offset = exact
      ? (sqlOffset < sql.text.length ? sql.offsets![sqlOffset] : sql.endOffset)
      : blockOffset;
  final before = source.substring(0, offset);
  final line = '\n'.allMatches(before).length + 1;
  final column =
      before.substring(before.lastIndexOf('\n') + 1).runes.length + 1;
  final sqlLine = '\n'.allMatches(prefix).length + 1;
  final sqlColumn =
      prefix.substring(prefix.lastIndexOf('\n') + 1).runes.length + 1;
  final detail = hasCursor
      ? 'SQL line $sqlLine, column $sqlColumn'
      : 'parser provided no error position';
  final locationNote = exact ? '' : '; SQL block starts here';
  stderr.writeln(
    'FAIL $path:$line:$column$variant: $message ($detail$locationNote)',
  );
  final excerpt = source.split('\n')[line - 1].replaceAll('\r', '');
  final gutter = '  $line | ';
  stderr.writeln('$gutter$excerpt');
  final leading = String.fromCharCodes(excerpt.runes.take(column - 1));
  final padding = leading.replaceAll(RegExp(r'[^\t]'), ' ');
  stderr.writeln('${' ' * gutter.length}$padding^');
}

_SqlText _normalizeParameters(
  _SqlText input, {
  Map<String, int>? parameterOffsets,
}) {
  final sql = input.text;
  final output = StringBuffer();
  final offsets = <int>[];
  final indexes = <String, int>{};
  var i = 0;
  while (i < sql.length) {
    var end = i + 1;
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
    } else if (sql[i] == "'" || sql[i] == '"') {
      final quote = sql[i];
      while (end < sql.length) {
        if (sql[end] == '\\') {
          end = (end + 2).clamp(0, sql.length);
        } else if (sql[end] == quote) {
          end++;
          if (end >= sql.length || sql[end] != quote) break;
          end++;
        } else {
          end++;
        }
      }
    } else {
      final dollar = _dollarQuote.matchAsPrefix(sql, i);
      if (dollar != null) {
        final close = sql.indexOf(dollar.group(0)!, dollar.end);
        end = close < 0 ? sql.length : close + dollar.group(0)!.length;
      } else {
        final parameter = _parameter.matchAsPrefix(sql, i);
        if (parameter != null) {
          final name = parameter.group(0)!;
          parameterOffsets?.putIfAbsent(name.substring(1), () => i);
          final index = indexes.putIfAbsent(name, () => indexes.length + 1);
          final placeholder = '\$$index';
          output.write(placeholder);
          if (input.offsets != null) {
            offsets.addAll(List.filled(placeholder.length, input.offsets![i]));
          }
          i = parameter.end;
          continue;
        }
      }
    }
    output.write(sql.substring(i, end));
    if (input.offsets != null) offsets.addAll(input.offsets!.sublist(i, end));
    i = end;
  }
  return _SqlText(
    output.toString(),
    input.offsets == null ? null : offsets,
    input.endOffset,
  );
}
