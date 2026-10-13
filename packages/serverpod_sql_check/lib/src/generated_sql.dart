/// Bounded evaluation of constant SQL expressions consumed by psql \gexec.
library;

import 'dart:convert';

import 'package:postgresql_parser/postgresql_parser.dart';

import 'psql_keywords.dart';

final class GeneratedSql {
  const GeneratedSql(
    this.gexecOffset,
    this.expressionOffset, {
    this.sql,
    this.reason,
    this.error,
    this.ignoredReason = 'NULL output ignored by \\gexec',
  });

  final int gexecOffset;
  final int expressionOffset;
  final String? sql;
  final String? reason;
  final String? error;
  final String ignoredReason;

  // No sql, reason or error means a known NULL or an empty result set.
}

/// Reads possible constant output values, without evaluating rows or predicates.
/// Locations are UTF-16 offsets in [sql], converted from PostgreSQL AST bytes.
List<GeneratedSql> generatedPsqlSql(
  ParseResult parsed,
  String sql,
  List<int> gexecOffsets,
) {
  final bytes = utf8.encode(sql);
  int offset(int position) =>
      position < 0 ? 0 : utf8.decode(bytes.sublist(0, position)).length;
  final statements = [
    for (final raw in parsed.tree['stmts'] as List)
      (
        node: (raw as Map)['stmt'] as Map,
        end: (raw['stmt_len'] as int? ?? 0) == 0
            ? sql.length
            : offset(
                (raw['stmt_location'] as int? ?? 0) + (raw['stmt_len'] as int),
              ),
      ),
  ];
  final evaluator = _Evaluator(parsed.version.major);
  final output = <GeneratedSql>[];
  for (final command in gexecOffsets) {
    // With an empty buffer, psql reuses the most recently sent query.
    final statement = statements.where((s) => s.end <= command).lastOrNull;
    final select = statement?.node['SelectStmt'] as Map?;
    if (select == null ||
        (select['op'] != null && select['op'] != 'SETOP_NONE') ||
        select['valuesLists'] != null) {
      output.add(
        GeneratedSql(
          command,
          command,
          reason: 'generator is not a supported SELECT target list',
        ),
      );
      continue;
    }
    final targets = select['targetList'] as List? ?? const [];
    if (targets.length > 32) {
      output.add(
        GeneratedSql(
          command,
          command,
          reason: 'generated SQL exceeds the 32-column limit',
        ),
      );
      continue;
    }
    final condition = (select['whereClause'] as Map?)?['A_Const'] as Map?;
    final limit = (select['limitCount'] as Map?)?['A_Const'] as Map?;
    final boolean = condition?['boolval'] as Map?;
    final integer = limit?['ival'] as Map?;
    final noRows =
        condition?['isnull'] == true ||
        boolean != null && (boolean['boolval'] as bool? ?? false) == false ||
        integer != null && (integer['ival'] as int? ?? 0) == 0;
    if (select['intoClause'] != null || targets.isEmpty || noRows) {
      output.add(
        GeneratedSql(
          command,
          command,
          ignoredReason: 'query has no result rows or columns for \\gexec',
        ),
      );
      continue;
    }
    for (final target in targets) {
      final value = (target as Map)['ResTarget'] as Map;
      final expressionOffset = offset(value['location'] as int? ?? -1);
      try {
        output.add(
          GeneratedSql(
            command,
            expressionOffset,
            sql: evaluator.text(evaluator.evaluate(value['val'] as Map)),
          ),
        );
      } on _Unknown catch (error) {
        output.add(
          GeneratedSql(command, expressionOffset, reason: error.message),
        );
      } on _Invalid catch (error) {
        output.add(
          GeneratedSql(command, expressionOffset, error: error.message),
        );
      }
    }
  }
  return output;
}

final class _Unknown implements Exception {
  const _Unknown(this.message);
  final String message;
}

final class _Invalid implements Exception {
  const _Invalid(this.message);
  final String message;
}

final class _Evaluator {
  _Evaluator(this.major);
  final int major;
  static const textLimit = 65536;
  static final _formatSpec = RegExp(
    r'%(?:(\d+)\$)?(-)?(?:(\d+)|\*(?:(\d+)\$)?)?([sIL])',
  );
  static final _safeIdentifier = RegExp(r'^[a-z_][a-z0-9_]*$');

  Object? evaluate(Map expression, [int depth = 0]) {
    if (depth > 32) {
      throw const _Unknown('constant SQL expression exceeds depth limit');
    }
    final constant = expression['A_Const'] as Map?;
    if (constant != null) {
      if (constant['isnull'] == true) return null;
      if (constant['sval'] case final Map value) {
        return bounded(value['sval'] as String? ?? '');
      }
      if (constant['ival'] case final Map value) {
        return value['ival'] as int? ?? 0;
      }
      if (constant['boolval'] case final Map value) {
        return value['boolval'] as bool? ?? false;
      }
    }
    final operator = expression['A_Expr'] as Map?;
    if (operator != null && operator['kind'] == 'AEXPR_OP') {
      final names = _names(operator['name']);
      if (names.length == 1 && names.single == '||') {
        final left = evaluate(operator['lexpr'] as Map, depth + 1);
        final right = evaluate(operator['rexpr'] as Map, depth + 1);
        if (left == null || right == null) return null;
        if (left is String && right is String) return bounded(left + right);
      } else if (names.length == 1 &&
          names.single == '-' &&
          operator['lexpr'] == null) {
        final value = evaluate(operator['rexpr'] as Map, depth + 1);
        if (value is int) return -value;
      }
    }
    final cast = expression['TypeCast'] as Map?;
    if (cast != null) {
      final names = _names((cast['typeName'] as Map)['names']);
      if (_builtin(names, 'text') &&
          (cast['typeName'] as Map)['typmods'] == null) {
        return text(evaluate(cast['arg'] as Map, depth + 1));
      }
    }
    final function = expression['FuncCall'] as Map?;
    if (function != null) {
      final names = _names(function['funcname']);
      if (_builtin(names, 'format') &&
          function['func_variadic'] != true &&
          function['agg_star'] != true &&
          function['agg_distinct'] != true &&
          function['agg_order'] == null &&
          function['agg_filter'] == null &&
          function['over'] == null) {
        return format(function['args'] as List? ?? const [], depth + 1);
      }
      throw _Unknown(
        'SQL function ${names.join('.')} is not statically evaluated',
      );
    }
    if (expression['ColumnRef'] case final Map column) {
      throw _Unknown(
        'column ${_names(column['fields']).join('.')} depends on database rows',
      );
    }
    throw const _Unknown('SQL expression is not a supported constant');
  }

  String bounded(String value) {
    if (value.length > textLimit) {
      throw const _Unknown('generated SQL exceeds text limit');
    }
    return value;
  }

  String? text(Object? value) => switch (value) {
    null => null,
    final String value => value,
    final int value => value.toString(),
    final bool value => value ? 't' : 'f',
    _ => throw const _Unknown(
      'SQL value has an unsupported text representation',
    ),
  };

  String quoteIdentifier(String value) {
    final keywords = psqlQuotedKeywords[major];
    if (keywords == null) {
      throw const _Unknown(
        'identifier quoting is unavailable for this grammar',
      );
    }
    return _safeIdentifier.hasMatch(value) && !keywords.contains(value)
        ? value
        : '"${value.replaceAll('"', '""')}"';
  }

  String quoteLiteral(String value) {
    final escaped = value.replaceAll('\\', '\\\\').replaceAll("'", "''");
    return "${value.contains('\\') ? 'E' : ''}'$escaped'";
  }

  String? format(List arguments, int depth) {
    if (arguments.isEmpty) {
      throw const _Unknown('format() has no readable format string');
    }
    final formatString = evaluate(arguments.first as Map, depth);
    if (formatString == null) return null;
    if (formatString is! String) {
      throw const _Unknown('format() string is not constant text');
    }
    var nextArgument = 1;
    Object? argument(int? position) {
      final index = position ?? nextArgument;
      if (index < 1 || index >= arguments.length) {
        throw const _Invalid(
          'format() has too few arguments or an invalid argument position',
        );
      }
      nextArgument = index + 1;
      return evaluate(arguments[index] as Map, depth);
    }

    final output = StringBuffer();
    var i = 0;
    while (i < formatString.length) {
      if (formatString[i] != '%') {
        output.write(formatString[i++]);
      } else if (formatString.startsWith('%%', i)) {
        output.write('%');
        i += 2;
      } else {
        final spec = _formatSpec.matchAsPrefix(formatString, i);
        if (spec == null) {
          throw const _Invalid('format() has an invalid conversion specifier');
        }
        int? position(String? value) {
          if (value == null) return null;
          final parsed = int.tryParse(value);
          if (parsed == null || parsed > 2147483647) {
            throw const _Invalid(
              'format() position or width is not a 32-bit integer',
            );
          }
          return parsed;
        }

        var width = position(spec.group(3)) ?? 0;
        var left = spec.group(2) != null;
        if (spec.group(0)!.contains('*')) {
          final value = argument(position(spec.group(4)));
          final parsed = value == null ? 0 : int.tryParse(text(value)!.trim());
          if (parsed == null || parsed < -2147483648 || parsed > 2147483647) {
            throw const _Invalid('format() width is not a 32-bit integer');
          }
          width = parsed;
          if (width < 0) {
            left = true;
            width = -width;
          }
        }
        if (width > textLimit) {
          throw const _Unknown('format() width exceeds text limit');
        }
        final value = text(argument(position(spec.group(1))));
        final converted = switch (spec.group(5)) {
          's' => value ?? '',
          'I' =>
            value == null
                ? throw const _Invalid(
                    'format() %I cannot quote a NULL identifier',
                  )
                : quoteIdentifier(value),
          'L' => value == null ? 'NULL' : quoteLiteral(value),
          _ => throw const _Invalid('format() has an invalid conversion type'),
        };
        final padding = width - converted.runes.length;
        if (!left && padding > 0) output.write(' ' * padding);
        output.write(converted);
        if (left && padding > 0) output.write(' ' * padding);
        i = spec.end;
      }
      if (output.length > textLimit) {
        throw const _Unknown('generated SQL exceeds text limit');
      }
    }
    return output.toString();
  }
}

List<String> _names(Object? value) => value is List
    ? [
        for (final raw in value)
          if ((raw as Map)['String'] case final Map item)
            item['sval'] as String,
      ]
    : const [];

bool _builtin(List<String> names, String name) =>
    names.length == 1 && names.single == name ||
    names.length == 2 && names.first == 'pg_catalog' && names.last == name;
