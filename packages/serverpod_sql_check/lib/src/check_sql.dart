/// Checks SQL with the local postgresql_parser package, without executing it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:serverpod_sql_check/src/dart_sources.dart';
import 'package:serverpod_sql_check/src/local_flow.dart';
import 'package:serverpod_sql_check/src/named_bindings.dart';
import 'package:serverpod_sql_check/src/static_evaluator.dart';
import 'package:serverpod_sql_check/src/static_objects.dart';
import 'package:serverpod_sql_check/src/static_value.dart';
import 'package:serverpod_sql_check/src/static_contexts.dart';
import 'package:serverpod_sql_check/src/static_demand.dart';
import 'package:serverpod_sql_check/src/server_discovery.dart';
import 'package:postgresql_parser/postgresql_parser.dart';

const _sqlKeywords = [
  'WITH',
  'SELECT',
  'INSERT',
  'UPDATE',
  'DELETE',
  'CREATE',
  'ALTER',
  'DROP',
  'DO',
  'TRUNCATE',
  'GRANT',
  'REVOKE',
  'COMMENT',
  'REFRESH',
  'VACUUM',
  'ANALYZE',
  'REINDEX',
  'BEGIN',
  'COMMIT',
  'ROLLBACK',
  'SET',
  'RESET',
  'CALL',
  'EXPLAIN',
];
final _sqlStart = RegExp(
  r'^\s*(?:(?:--[^\n]*\n|/\*[\s\S]*?\*/)\s*)*(?:'
  '${_sqlKeywords.join('|')}'
  r')\s+',
);
final _parameter = RegExp(r'@[A-Za-z_][A-Za-z_0-9]*');
final _dollarQuote = RegExp(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$');
const _rawMethods = {'unsafeQuery', 'unsafeExecute'};

/// Checks SQL, PL/pgSQL, and bindings, and sets [exitCode] on failure.
void checkSql(List<String> args) {
  var includeMigrations = false;
  var verbose = false;
  var major = 17;
  String? explicitRoot;
  final paths = <String>[];
  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      stdout.writeln(
        'Usage: dart run serverpod_sql_check [options] [file or directory ...]\n'
        '  --include-migrations    Include migration SQL (excluded by default)\n'
        '  --postgres-version=17   PostgreSQL grammar: 17 (default) or 18\n'
        '  --verbose               Print checked and skipped query locations\n'
        '  --root=<directory>      Explicit scan root; overrides server discovery\n'
        'With no paths or root, detect a server by its serverpod dependency.\n'
        'Multiple servers or no server require --root. Dynamic SQL is skipped.\n'
        'PL/pgSQL function, procedure, and DO bodies are checked automatically.\n'
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
      explicitRoot = arg.substring('--root='.length);
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
  final String root;
  try {
    root = resolveScanRoot(
      currentDirectory: Directory.current,
      explicitRoot: explicitRoot,
      hasPaths: paths.isNotEmpty,
    ).path;
  } on ServerDiscoveryException catch (error) {
    stderr.writeln('ERROR: $error');
    exitCode = 2;
    return;
  } on FileSystemException catch (error) {
    stderr.writeln('ERROR: $error');
    exitCode = 2;
    return;
  }
  if (explicitRoot == null && paths.isEmpty) {
    stdout.writeln('Detected Serverpod server: $root');
  }
  final parser = PostgresParser(version: versions.single);
  final sources = DartSources();
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
  var plpgsqlChecked = 0;
  var plpgsqlFailed = 0;
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
              _Block(0, [
                _SqlText.original(SourceFile(file.absolute.path, source)),
              ]),
            ]
          : _dartSql(source, file.absolute.path, sources);
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
          final bindings = block.variantBindings?[variant] ?? block.bindings;
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
              final uncertain = parameterOffsets.keys.any(
                (name) =>
                    !keys.contains(name) && bindings.possible!.contains(name),
              );
              if (uncertain) {
                bindingsSkipped++;
                if (verbose) {
                  stdout.writeln(
                    'SKIP BINDINGS $variantLabel (a required key is conditional)',
                  );
                }
              } else {
                bindingsChecked++;
              }
              final available = keys.isEmpty
                  ? '<none>'
                  : (keys.toList()..sort()).join(', ');
              for (final parameter in parameterOffsets.entries) {
                if (bindings.possible!.contains(parameter.key)) continue;
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
                  root: root,
                );
              }
            }
          }
          checked++;
          try {
            final result = parser.parse(sql);
            var bodyFailed = false;
            for (final definition in _plpgsqlStatements(result, prepared)) {
              final statement = definition.sql;
              plpgsqlChecked++;
              try {
                // Older upstream compilers assert when a definition has no AS
                // body. Diagnose it before calling the native PL/pgSQL parser.
                if (!definition.hasBody) {
                  throw PostgresParseException(
                    version: parser.version,
                    message: 'definition requires an AS body',
                    cursorPosition: 0,
                  );
                }
                parser.parsePlpgsql(statement.text);
              } on PostgresParseException catch (error) {
                bodyFailed = true;
                plpgsqlFailed++;
                _reportSqlFailure(
                  _displayPath(file.absolute.path, root),
                  source,
                  block.offset,
                  statement,
                  null,
                  'PL/pgSQL: ${error.message}',
                  block.variants!.length > 1 ? ' (variant ${variant + 1})' : '',
                  positionDetail: error.cursorPosition > 0
                      ? 'PL/pgSQL parser position ${error.cursorPosition}'
                      : 'PL/pgSQL parser provided no error position',
                  blockLocationNote: 'PL/pgSQL block starts here',
                  blockOrigin: statement.origins?.firstOrNull,
                  root: root,
                );
              }
            }
            if (bodyFailed) failed++;
            if (verbose && !missingBindings && !bodyFailed) {
              stdout.writeln('OK $variantLabel');
            }
          } on PostgresParseException catch (error) {
            // CTE helpers deliberately contain only a WITH clause. Complete that
            // fragment to validate its grammar; raw calls require a full query.
            if (!isSql &&
                !block.isRawQuery &&
                RegExp(r'^\s*WITH\b').hasMatch(sql) &&
                error.message == 'syntax error at end of input') {
              try {
                final needsCte =
                    RegExp(r'^\s*WITH(?:\s+RECURSIVE)?\s*$').hasMatch(sql) ||
                    sql.trimRight().endsWith(',');
                final completion = needsCte
                    ? '__serverpod_sql_check_fragment__ AS (SELECT 1) SELECT 1;'
                    : 'SELECT 1;';
                parser.parse('$sql\n$completion');
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
              root: root,
            );
          }
        }
      }
    } on FileSystemException catch (error) {
      stderr.writeln('ERROR: $error');
      operationalErrors++;
    } on FormatException catch (error) {
      stderr.writeln('ERROR: $error');
      operationalErrors++;
    }
  }
  stdout.writeln(
    'Scanned $sqlFiles SQL files and $dartFiles Dart files.\n'
    'Checked $checked SQL variants; $failed failed; $skipped dynamic queries/templates skipped.\n'
    'Checked $plpgsqlChecked PL/pgSQL definitions; $plpgsqlFailed failed.\n'
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

// Use the SQL tree to select the language, rather than matching text inside
// comments or strings. Parse each definition separately so unrelated function
// languages cannot affect PL/pgSQL checks and failures do not hide later bodies.
Iterable<({_SqlText sql, bool hasBody})> _plpgsqlStatements(
  ParseResult result,
  _SqlText sql,
) sync* {
  final bytes = utf8.encode(sql.text);
  for (final raw in result.tree['stmts'] as List) {
    final statement = raw as Map<String, dynamic>;
    final node = statement['stmt'] as Map<String, dynamic>;
    final function = node['CreateFunctionStmt'] as Map<String, dynamic>?;
    final inline = node['DoStmt'] as Map<String, dynamic>?;
    if (function == null && inline == null) continue;
    final options =
        (function?['options'] ?? inline?['args'] ?? const []) as List;
    var language = inline == null ? null : 'plpgsql';
    var hasBody = false;
    for (final option in options) {
      final definition = (option as Map)['DefElem'] as Map;
      if (definition['defname'] == 'language') {
        language =
            ((definition['arg'] as Map)['String'] as Map)['sval'] as String;
      }
      if (definition['defname'] == 'as') hasBody = true;
    }
    if (language != 'plpgsql') continue;

    // PostgreSQL locations count UTF-8 bytes; Dart text and the origin map count
    // UTF-16 code units. Convert before slicing, including after Unicode text.
    final location = statement['stmt_location'] as int? ?? 0;
    final length = statement['stmt_len'] as int? ?? 0;
    final start = utf8.decode(bytes.sublist(0, location)).length;
    final end = length == 0
        ? sql.text.length
        : start +
              utf8.decode(bytes.sublist(location, location + length)).length;
    final leading = RegExp(r'^\s*')
        .firstMatch(sql.text.substring(start, end))!
        .end;
    final trimmedStart = start + leading;
    yield (
      sql: _SqlText(
        sql.text.substring(trimmedStart, end),
        sql.origins?.sublist(trimmedStart, end),
        sql.origins != null && end < sql.text.length
            ? sql.origins![end]
            : sql.endOrigin,
      ),
      hasBody: hasBody,
    );
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
  _Block(
    this.offset,
    this.variants, {
    this.isRawQuery = false,
    this.bindings,
    this.variantBindings,
    this.reason = 'unresolved string reference or runtime SQL expression',
  });
  final int offset;
  final List<_SqlText>? variants;
  final String reason;
  final bool isRawQuery;
  final NamedBindings? bindings;
  final List<NamedBindings?>? variantBindings;
}

List<_Block> _dartSql(String source, String path, DartSources sources) {
  final unit = sources.unitFor(path, content: source);
  final finder = _RawQueryFinder();
  unit.unit.accept(finder);
  final visitor = _SqlVisitor(finder.found, unit);
  final assembly = _AssemblyFragments(unit);
  unit.unit.accept(assembly);
  unit.unit.accept(_AssemblyCalls(unit, assembly.receivers, assembly.nodes));
  visitor.assembly.addAll(assembly.nodes);
  visitor.assemblyReceivers.addAll(assembly.receivers);
  unit.unit.accept(visitor);
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
  _SqlVisitor(this.hasRawCalls, this.unit);
  final bool hasRawCalls;
  final DartUnit unit;
  final blocks = <int, _Block>{};
  final assembly = <AstNode>{};
  final assemblyReceivers = <AstNode>{};
  final objects = SourceObjects();
  late final evaluator = StaticEvaluator(
    mapText: (value, source, start, end, raw) =>
        _staticText(_mappedValue(value, source, start, end, raw)),
    objects: objects,
  );
  late final contexts = StaticContexts(unit, evaluator, objects);
  String? _resolutionReason;

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
        parameters: parameters,
        bindings: _namedBindings(parameters, unit),
      );
    }
    if (node.methodName.name == 'join' || node.methodName.name == 'toString') {
      final target = node.target;
      if (_templateContext(node) ||
          target is ListLiteral ||
          target != null && _assemblyReceiver(target, {})) {
        _add(node);
      }
    }
    super.visitMethodInvocation(node);
  }

  bool _assemblyReceiver(Expression expression, Set<AstNode> active) {
    final declaration = unit.references.targetFor(expression);
    if (assemblyReceivers.contains(declaration)) return true;
    if (declaration is! VariableDeclaration || !active.add(declaration)) {
      return false;
    }
    final initializer = declaration.initializer;
    return initializer != null && _assemblyReceiver(initializer, active);
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

  void _add(
    Expression node, {
    bool force = false,
    Expression? parameters,
    NamedBindings? bindings,
  }) {
    if (!force) {
      if (blocks[node.offset]?.isRawQuery ?? false) return;
      if (!hasRawCalls && !_templateContext(node)) return;
      if (node is SimpleStringLiteral && !_sqlStart.hasMatch(node.value)) {
        return;
      }
      if (node is StringInterpolation) {
        final head = _prefix(node).trimLeft();
        if (head.isNotEmpty &&
            !_sqlStart.hasMatch(head) &&
            !_sqlKeywords.any((keyword) => keyword.startsWith(head)) &&
            !head.startsWith('--') &&
            !head.startsWith('/*') &&
            head != '-' &&
            head != '/') {
          return;
        }
      }
      for (
        AstNode? parent = node.parent;
        parent != null;
        parent = parent.parent
      ) {
        if (parent is StringInterpolation || parent is AdjacentStrings) return;
        if (assembly.contains(parent)) return;
      }
    }
    _resolutionReason = null;
    final resolved = _resolve(node, parameters, force);
    final variants = resolved?.texts ?? _variants(node, unit);
    final prefix = variants?.firstOrNull?.text ?? _prefix(node);
    if (force ||
        (_sqlStart.hasMatch(prefix) &&
            (hasRawCalls || _templateContext(node)))) {
      blocks[node.offset] = _Block(
        node.offset,
        variants,
        isRawQuery: force || (blocks[node.offset]?.isRawQuery ?? false),
        bindings: bindings ?? blocks[node.offset]?.bindings,
        variantBindings: resolved?.bindings,
        reason:
            _resolutionReason ??
            'unresolved string reference or runtime SQL expression',
      );
    }
  }

  _StaticResolution? _resolve(
    Expression expression,
    Expression? parameters,
    bool raw,
  ) {
    // Literal SQL and fresh, fixed binding keys cannot depend on earlier flow.
    // Avoid replaying a large builder merely to check an independent literal.
    final literalBindings = raw && parameters != null
        ? _literalParameterBindings(parameters, unit)
        : null;
    if (_literalSql(expression) &&
        (!raw || parameters == null || literalBindings != null)) {
      final resolved = _resolveFrames(expression, null, raw, [
        StaticFrame(unit),
      ]);
      if (resolved != null) {
        return literalBindings == null
            ? resolved
            : _StaticResolution(resolved.texts, [literalBindings]);
      }
    }
    final demand = StaticDemand(expression, parameters, unit);
    final frames = evaluator.framesAt(
      expression,
      unit,
      needed: demand.needed,
      keysOnly: demand.keysOnly,
    );
    final direct = _resolveFrames(expression, parameters, raw, frames);
    if (direct != null) return direct;
    return _resolveFrames(
      expression,
      parameters,
      raw,
      contexts.framesAt(
        expression,
        needed: demand.needed,
        keysOnly: demand.keysOnly,
      ),
    );
  }

  bool _literalSql(Expression expression) {
    if (expression is ParenthesizedExpression) {
      return _literalSql(expression.expression);
    }
    return expression is SimpleStringLiteral ||
        expression is AdjacentStrings && expression.strings.every(_literalSql);
  }

  _StaticResolution? _resolveFrames(
    Expression expression,
    Expression? parameters,
    bool raw,
    List<StaticFrame> frames,
  ) {
    if (frames.isEmpty) return null;
    final groups = <String, _StaticVariant>{};
    final literalBindings = raw && parameters != null
        ? _literalParameterBindings(parameters, unit)
        : null;
    var expanded = 0;
    for (final frame in frames) {
      for (final sql in evaluator.evaluate(expression, frame)) {
        if (sql.value is! TextValue) {
          final unknown = sql.value;
          _resolutionReason = unknown is UnknownValue
              ? unknown.reason
              : 'SQL expression does not produce a string';
          return null;
        }
        final text = _sqlText((sql.value as TextValue).text);
        final available = !raw
            ? <NamedBindings?>[null]
            : parameters == null
            ? <NamedBindings?>[NamedBindings({})]
            : [
                for (final result in evaluator.evaluate(parameters, sql.frame))
                  _staticBindings(result.value).keys != null
                      ? _staticBindings(result.value)
                      : literalBindings ?? NamedBindings(null),
              ];
        if (available.isEmpty) available.add(NamedBindings(null));
        final group = groups.putIfAbsent(text.text, () => _StaticVariant(text));
        group.bindings.addAll(available);
        expanded += available.length;
        if (groups.length > 32 || expanded > 32) {
          _resolutionReason = 'static query expansion exceeds 32 paths';
          return null;
        }
      }
    }
    if (groups.isEmpty) return null;
    return _StaticResolution(
      [for (final group in groups.values) group.text],
      [
        for (final group in groups.values)
          raw ? _mergeStaticBindings(group.bindings) : null,
      ],
    );
  }
}

// Fragments consumed by a recognized list/buffer assembly are checked through
// the complete query. A procedural BEGIN fragment is not standalone SQL.
final class _AssemblyFragments extends RecursiveAstVisitor<void> {
  _AssemblyFragments(this.unit);
  final DartUnit unit;
  final nodes = <AstNode>{};
  final receivers = <AstNode>{};
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (node.methodName.name == 'join' && target != null) {
      if (target is ListLiteral) nodes.add(target);
      final declaration = unit.references.targetFor(target);
      if (declaration is VariableDeclaration) _list(declaration, {});
    } else if (node.methodName.name == 'toString' && target != null) {
      final declaration = unit.references.targetFor(target);
      if (declaration is VariableDeclaration) _buffer(declaration, {});
    }
    super.visitMethodInvocation(node);
  }

  void _list(VariableDeclaration declaration, Set<AstNode> active) {
    if (!active.add(declaration)) return;
    final initializer = declaration.initializer;
    if (initializer is ListLiteral) {
      nodes.add(initializer);
      receivers.add(declaration);
    } else if (initializer != null) {
      final alias = unit.references.targetFor(initializer);
      if (alias is VariableDeclaration) {
        _list(alias, active);
        if (receivers.contains(alias)) receivers.add(declaration);
      }
    }
  }

  void _buffer(VariableDeclaration declaration, Set<AstNode> active) {
    if (!active.add(declaration)) return;
    var initializer = declaration.initializer;
    if (initializer is CascadeExpression) initializer = initializer.target;
    final buffer =
        initializer is MethodInvocation &&
            initializer.target == null &&
            initializer.methodName.name == 'StringBuffer' &&
            !unit.references.shadowsName('StringBuffer', initializer) &&
            unit.sources.resolveTypeNames(
                  ['StringBuffer'],
                  initializer,
                  unit,
                ) ==
                null ||
        initializer is InstanceCreationExpression &&
            initializer.constructorName.type.name.lexeme == 'StringBuffer' &&
            !unit.references.shadowsName('StringBuffer', initializer) &&
            unit.sources.resolveNamedType(
                  initializer.constructorName.type,
                  initializer,
                  unit,
                ) ==
                null;
    if (buffer) {
      receivers.add(declaration);
      nodes.add(declaration.initializer!);
    } else if (initializer != null) {
      final alias = unit.references.targetFor(initializer);
      if (alias is VariableDeclaration) {
        _buffer(alias, active);
        if (receivers.contains(alias)) receivers.add(declaration);
      }
    }
  }
}

final class _AssemblyCalls extends RecursiveAstVisitor<void> {
  _AssemblyCalls(this.unit, this.receivers, this.nodes);
  final DartUnit unit;
  final Set<AstNode> receivers;
  final Set<AstNode> nodes;

  bool _receiver(Expression expression, Set<AstNode> active) {
    final declaration = unit.references.targetFor(expression);
    if (receivers.contains(declaration)) return true;
    if (declaration is! VariableDeclaration ||
        !active.add(declaration) ||
        active.length > 32) {
      return false;
    }
    final initializer = declaration.initializer;
    return initializer != null && _receiver(initializer, active);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target ?? (node.isCascaded ? _cascade(node) : null);
    if (target != null &&
        _receiver(target, {}) &&
        {
          'add',
          'addAll',
          'write',
          'writeln',
          'writeAll',
        }.contains(node.methodName.name)) {
      nodes.add(node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  Expression? _cascade(AstNode node) {
    for (AstNode? owner = node.parent; owner != null; owner = owner.parent) {
      if (owner is CascadeExpression) return owner.target;
      if (owner is Statement) return null;
    }
    return null;
  }
}

final class _StaticVariant {
  _StaticVariant(this.text);
  final _SqlText text;
  final List<NamedBindings?> bindings = [];
}

final class _StaticResolution {
  _StaticResolution(this.texts, this.bindings);
  final List<_SqlText> texts;
  final List<NamedBindings?> bindings;
}

StaticText _staticText(_SqlText value) => StaticText(
  value.text,
  value.origins
      ?.map((origin) => StaticOrigin(origin.file, origin.offset))
      .toList(),
  StaticOrigin(value.endOrigin.file, value.endOrigin.offset),
);
_SqlText _sqlText(StaticText value) => _SqlText(
  value.text,
  value.origins?.map((origin) => _Origin(origin.file, origin.offset)).toList(),
  _Origin(value.endOrigin.file, value.endOrigin.offset),
);

NamedBindings _staticBindings(StaticValue value) {
  if (value is ScalarValue && value.value == null) return NamedBindings({});
  if (value is BindingsValue && value.map.known) {
    return NamedBindings(value.map.entries.keys.toSet());
  }
  return NamedBindings(null);
}

NamedBindings _mergeStaticBindings(List<NamedBindings?> alternatives) {
  Set<String>? guaranteed;
  final possible = <String>{};
  for (final bindings in alternatives) {
    if (bindings?.keys == null) return NamedBindings(null);
    guaranteed = guaranteed == null
        ? {...bindings!.keys!}
        : guaranteed.intersection(bindings!.keys!);
    possible.addAll(bindings.possible!);
  }
  return NamedBindings(guaranteed ?? {}, possible: possible);
}

NamedBindings _namedBindings(Expression? expression, DartUnit unit) =>
    namedBindings(
      expression,
      unit,
      (node, source) =>
          _variants(node, source)?.map((text) => text.text).toList(),
    );

// Runtime values can expand into many branches without changing a fresh map's
// fixed keys. Those values cannot remove entries from the map being created.
NamedBindings? _literalParameterBindings(Expression expression, DartUnit unit) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  final ArgumentList? arguments = expression is MethodInvocation
      ? expression.argumentList
      : expression is InstanceCreationExpression
      ? expression.argumentList
      : null;
  if (arguments == null || arguments.arguments.length != 1) return null;
  final map = arguments.arguments.single.argumentExpression;
  if (map is! SetOrMapLiteral ||
      map.elements.any(
        (element) =>
            element is! MapLiteralEntry || element.key is! SimpleStringLiteral,
      )) {
    return null;
  }
  final bindings = _namedBindings(expression, unit);
  return bindings.keys == null ? null : bindings;
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
  DartUnit unit, {
  Set<AstNode>? active,
  Map<AstNode, List<_SqlText>?>? arguments,
}) {
  if (!unit.readable) return null;
  active ??= {};
  arguments ??= {};
  if (active.length >= 32) return null;
  List<_SqlText>? evaluate(Expression node) =>
      _variants(node, unit, active: active, arguments: arguments);
  if (expression is SimpleIdentifier ||
      expression is PrefixedIdentifier ||
      expression is PropertyAccess ||
      expression is MethodInvocation) {
    final target = unit.sources.resolve(expression, unit);
    if (target == null) return null;
    final declaration = target.node;
    if (expression is MethodInvocation) {
      return _helperVariants(expression, unit, target, active, arguments);
    }
    if (declaration is FormalParameter) return arguments[declaration];
    if (arguments.containsKey(declaration)) return arguments[declaration];
    if (declaration is! VariableDeclaration) return null;
    final field = declaration.parent?.parent;
    if (field is FieldDeclaration &&
        !field.isStatic &&
        !_instanceMemberDispatchSafe(declaration, target.unit)) {
      return null;
    }
    final list = declaration.parent;
    if (list is! VariableDeclarationList ||
        list.isLate ||
        !active.add(declaration)) {
      return null;
    }
    try {
      if (!list.isConst && !list.isFinal) {
        return _localStringVariants(
          declaration,
          expression,
          target.unit,
          active,
          arguments,
        );
      }
      if (declaration.initializer == null) return null;
      return _variants(
        declaration.initializer!,
        target.unit,
        active: active,
        arguments: arguments,
      );
    } finally {
      active.remove(declaration);
    }
  }
  if (expression is SimpleStringLiteral) {
    return [
      _mappedValue(
        expression.value,
        unit,
        expression.contentsOffset,
        expression.contentsEnd,
        expression.isRaw,
      ),
    ];
  }
  if (expression is ParenthesizedExpression) {
    return evaluate(expression.expression);
  }
  if (expression is ConditionalExpression) {
    final condition = expression.condition;
    if (condition is BooleanLiteral) {
      return evaluate(
        condition.value ? expression.thenExpression : expression.elseExpression,
      );
    }
    final yes = evaluate(expression.thenExpression);
    final no = evaluate(expression.elseExpression);
    if (yes == null || no == null) return null;
    final values = _unique([...yes, ...no]);
    return values.length > 32 ? null : values;
  }
  if (expression is SwitchExpression) {
    var values = <_SqlText>[];
    for (final branch in expression.cases) {
      final result = evaluate(branch.expression);
      if (result == null) return null;
      values = _unique([...values, ...result]);
      if (values.length > 32) return null;
    }
    return values.isEmpty ? null : values;
  }
  if (expression is BinaryExpression && expression.operator.lexeme == '+') {
    return _combine(
      evaluate(expression.leftOperand),
      evaluate(expression.rightOperand),
    );
  }
  if (expression is AdjacentStrings) {
    List<_SqlText>? result = [
      _SqlText('', [], _Origin(unit, expression.offset)),
    ];
    for (final string in expression.strings) {
      result = _combine(result, evaluate(string));
    }
    return result;
  }
  if (expression is StringInterpolation) {
    List<_SqlText>? result = [
      _SqlText('', [], _Origin(unit, expression.offset)),
    ];
    for (final element in expression.elements) {
      final values = element is InterpolationString
          ? [
              _mappedValue(
                element.value,
                unit,
                element.contentsOffset,
                element.contentsEnd,
                false,
              ),
            ]
          : evaluate((element as InterpolationExpression).expression);
      result = _combine(result, values);
    }
    return result;
  }
  return null;
}

List<_SqlText>? _localStringVariants(
  VariableDeclaration declaration,
  Expression use,
  DartUnit unit,
  Set<AstNode> active,
  Map<AstNode, List<_SqlText>?> arguments,
) {
  List<_SqlText>? evaluate(Expression expression, List<_SqlText>? value) =>
      _variants(
        expression,
        unit,
        active: active,
        arguments: {...arguments, declaration: value},
      );
  return localValueAt<List<_SqlText>>(
    declaration: declaration,
    use: use,
    references: unit.references,
    initial: declaration.initializer == null
        ? null
        : evaluate(declaration.initializer!, null),
    update: (statement, value) {
      if (statement is! ExpressionStatement) return null;
      final assignment = statement.expression;
      if (assignment is! AssignmentExpression ||
          !identical(
            unit.references.targetFor(assignment.leftHandSide),
            declaration,
          )) {
        return null;
      }
      final right = evaluate(assignment.rightHandSide, value);
      return (
        value: switch (assignment.operator.lexeme) {
          '=' => right,
          '+=' => _combine(value, right),
          _ => null,
        },
      );
    },
    merge: (yes, no) {
      if (yes == null || no == null) return null;
      final values = _unique([...yes, ...no]);
      return values.length > 32 ? null : values;
    },
  );
}

List<_SqlText>? _helperVariants(
  MethodInvocation call,
  DartUnit caller,
  DartDeclaration target,
  Set<AstNode> active,
  Map<AstNode, List<_SqlText>?> arguments,
) {
  final node = target.node;
  final FunctionBody body;
  final FormalParameterList? parameters;
  if (node is FunctionDeclaration && node.propertyKeyword == null) {
    body = node.functionExpression.body;
    parameters = node.functionExpression.parameters;
  } else if (node is MethodDeclaration &&
      (node.isStatic || _readableInstanceCall(call, target)) &&
      node.propertyKeyword == null) {
    body = node.body;
    parameters = node.parameters;
  } else {
    return null;
  }
  if (body.isAsynchronous || body.isGenerator || active.contains(node)) {
    return null;
  }
  final mutations = _Mutations();
  body.accept(mutations);
  if (mutations.found) return null;
  final positional = <Expression>[];
  final named = <String, Expression>{};
  for (final argument in call.argumentList.arguments) {
    if (argument is NamedArgument) {
      if (named.containsKey(argument.name.lexeme)) return null;
      named[argument.name.lexeme] = argument.argumentExpression;
    } else {
      positional.add(argument.argumentExpression);
    }
  }
  final bound = {...arguments};
  if (node is MethodDeclaration && !node.isStatic) bound[node] = null;
  var position = 0;
  for (final parameter in parameters?.parameters ?? <FormalParameter>[]) {
    final value = parameter.isNamed
        ? named.remove(parameter.name?.lexeme)
        : position < positional.length
        ? positional[position++]
        : null;
    if (value == null && parameter.isRequired) return null;
    bound[parameter] = value != null
        ? _variants(value, caller, active: active, arguments: arguments)
        : parameter.defaultClause == null
        ? null
        : _variants(
            parameter.defaultClause!.value,
            target.unit,
            active: active,
          );
  }
  if (position != positional.length || named.isNotEmpty) return null;
  active.add(node);
  try {
    List<_SqlText>? evaluate(Expression expression) =>
        _variants(expression, target.unit, active: active, arguments: bound);
    if (body is ExpressionFunctionBody) return evaluate(body.expression);
    if (body is! BlockFunctionBody) return null;
    final flow = _returns(body.block, evaluate);
    return flow == null || flow.fallsThrough ? null : flow.values;
  } finally {
    active.remove(node);
  }
}

bool _readableInstanceCall(MethodInvocation call, DartDeclaration target) {
  if (call.target != null && call.target is! ThisExpression) return false;
  return _instanceMemberDispatchSafe(target.node, target.unit);
}

bool _instanceMemberDispatchSafe(AstNode member, DartUnit unit) {
  final owner = member is MethodDeclaration
      ? member.parent?.parent
      : member.parent?.parent?.parent?.parent;
  if (owner is! ClassDeclaration) return false;
  // Private names can only be overridden in this library. Parts and any other
  // local declaration of that member make dispatch uncertain.
  final name = member is MethodDeclaration
      ? member.name.lexeme
      : (member as VariableDeclaration).name.lexeme;
  if ((!name.startsWith('_') && owner.finalKeyword == null) ||
      unit.unit.directives.any(
        (d) => d is PartDirective || d is PartOfDirective,
      )) {
    return false;
  }
  for (final declaration in unit.unit.declarations) {
    if (!identical(declaration, owner) &&
        unit.references.declaresMember(declaration, name)) {
      return false;
    }
    if (!name.startsWith('_')) {
      // Final classes can still be extended within their own library. A mixin
      // on a subclass may override a member without declaring it on the class.
      if (declaration is ClassTypeAlias) return false;
      if (declaration is ClassDeclaration && !identical(declaration, owner)) {
        final parent = declaration.extendsClause?.superclass;
        if (parent != null) {
          final base = unit.declarations[parent.name.lexeme];
          if (identical(base, owner) ||
              base is! ClassDeclaration ||
              base.extendsClause != null) {
            return false;
          }
        }
      }
    }
  }
  return true;
}

typedef _ReturnFlow = ({List<_SqlText> values, bool fallsThrough});

_ReturnFlow? _returns(
  Statement statement,
  List<_SqlText>? Function(Expression) evaluate,
) {
  if (statement is ReturnStatement) {
    final expression = statement.expression;
    final values = expression == null ? null : evaluate(expression);
    return values == null ? null : (values: values, fallsThrough: false);
  }
  if (statement is Block) {
    var values = <_SqlText>[];
    for (final child in statement.statements) {
      final result = _returns(child, evaluate);
      if (result == null) return null;
      values = _unique([...values, ...result.values]);
      if (values.length > 32) return null;
      if (!result.fallsThrough) return (values: values, fallsThrough: false);
    }
    return (values: values, fallsThrough: true);
  }
  if (statement is IfStatement) {
    final condition = statement.expression;
    if (condition is BooleanLiteral && statement.caseClause == null) {
      final selected = condition.value
          ? statement.thenStatement
          : statement.elseStatement;
      return selected == null
          ? (values: [], fallsThrough: true)
          : _returns(selected, evaluate);
    }
    final yes = _returns(statement.thenStatement, evaluate);
    final no = statement.elseStatement == null
        ? (values: <_SqlText>[], fallsThrough: true)
        : _returns(statement.elseStatement!, evaluate);
    if (yes == null || no == null) return null;
    final values = _unique([...yes.values, ...no.values]);
    return values.length > 32
        ? null
        : (values: values, fallsThrough: yes.fallsThrough || no.fallsThrough);
  }
  if (statement is FunctionDeclarationStatement) {
    return (values: [], fallsThrough: true);
  }
  if (statement is VariableDeclarationStatement) {
    final variables = statement.variables;
    if ((variables.isConst || variables.isFinal) &&
        !variables.isLate &&
        variables.variables.every((v) => v.initializer != null)) {
      return (values: [], fallsThrough: true);
    }
  }
  return null;
}

final class _Mutations extends RecursiveAstVisitor<void> {
  var found = false;

  @override
  void visitAssignmentExpression(AssignmentExpression node) => found = true;

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (node.operator.lexeme == '++' || node.operator.lexeme == '--') {
      found = true;
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    found = true;
  }
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
          a.origins == null || b.origins == null
              ? null
              : [...a.origins!, ...b.origins!],
          b.endOrigin,
        ),
  ]);
}

// Every SQL code unit retains its original file and offset across imports,
// helper returns, escapes, branch expansion, and parameter rewriting.
final class _Origin {
  _Origin(this.file, this.offset);
  final SourceFile file;
  final int offset;
}

final class _SqlText {
  _SqlText(this.text, this.origins, this.endOrigin);
  factory _SqlText.original(SourceFile file) => _SqlText(
    file.content,
    List.generate(file.content.length, (i) => _Origin(file, i)),
    _Origin(file, file.content.length),
  );
  final String text;
  final List<_Origin>? origins;
  final _Origin endOrigin;
}

_SqlText _mappedValue(
  String value,
  SourceFile file,
  int start,
  int end,
  bool raw,
) {
  final source = file.content;
  final decoded = StringBuffer();
  final origins = <_Origin>[];
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
          return _SqlText(value, null, _Origin(file, end));
        }
        final rune = int.tryParse(
          source.substring(digitsStart, digitsEnd),
          radix: 16,
        );
        if (rune == null || rune > 0x10ffff) {
          return _SqlText(value, null, _Origin(file, end));
        }
        character = String.fromCharCode(rune);
        i = digitsEnd + (braced ? 1 : 0);
      } else {
        character = escapes[escaped] ?? escaped;
      }
    }
    decoded.write(character);
    origins.addAll(List.filled(character.length, _Origin(file, origin)));
  }
  // Analyzer remains authoritative about Dart decoding. If a source form is
  // unsupported here, report the block location explicitly instead of guessing.
  return _SqlText(
    value,
    decoded.toString() == value ? origins : null,
    _Origin(file, end),
  );
}

void _reportFailure(
  String path,
  String source,
  int blockOffset,
  _SqlText sql,
  PostgresParseException error,
  String variant, {
  required String root,
}) {
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
    root: root,
  );
}

void _reportSqlFailure(
  String path,
  String source,
  int blockOffset,
  _SqlText sql,
  int? sqlOffset,
  String message,
  String variant, {
  required String root,
  _Origin? blockOrigin,
  String? positionDetail,
  String blockLocationNote = 'SQL block starts here',
}) {
  final hasCursor = sqlOffset != null;
  final prefix = hasCursor ? sql.text.substring(0, sqlOffset) : '';
  final exact = hasCursor && sql.origins != null;
  final origin = exact
      ? (sqlOffset < sql.text.length ? sql.origins![sqlOffset] : sql.endOrigin)
      : blockOrigin;
  if (origin != null) {
    path = _displayPath(origin.file.path, root);
    source = origin.file.content;
  }
  final offset = origin?.offset ?? blockOffset;
  final before = source.substring(0, offset);
  final line = '\n'.allMatches(before).length + 1;
  final column =
      before.substring(before.lastIndexOf('\n') + 1).runes.length + 1;
  final sqlLine = '\n'.allMatches(prefix).length + 1;
  final sqlColumn =
      prefix.substring(prefix.lastIndexOf('\n') + 1).runes.length + 1;
  final detail =
      positionDetail ??
      (hasCursor
          ? 'SQL line $sqlLine, column $sqlColumn'
          : 'parser provided no error position');
  final locationNote = exact ? '' : '; $blockLocationNote';
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
  final origins = <_Origin>[];
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
          if (input.origins != null) {
            origins.addAll(List.filled(placeholder.length, input.origins![i]));
          }
          i = parameter.end;
          continue;
        }
      }
    }
    output.write(sql.substring(i, end));
    if (input.origins != null) origins.addAll(input.origins!.sublist(i, end));
    i = end;
  }
  return _SqlText(
    output.toString(),
    input.origins == null ? null : origins,
    input.endOrigin,
  );
}
