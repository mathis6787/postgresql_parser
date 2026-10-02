import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Query dependency slicing must preserve every effect on SQL and bindings.
void staticDemandTests(
  Directory Function() fixture,
  Future<ProcessResult> Function(Directory, List<String>) run,
) {
  Future<ProcessResult> check(String source) {
    expect(
      parseString(content: source, throwIfDiagnostics: false).errors,
      isEmpty,
      reason: 'The fixture must contain syntactically valid Dart:\n$source',
    );
    final file = File(p.join(fixture().path, 'endpoint.dart'));
    file.writeAsStringSync(source);
    return run(fixture(), ['--root=${fixture().path}', '--verbose', file.path]);
  }

  void checked(ProcessResult result, {int count = 1}) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked $count SQL variants; 0 failed; 0 dynamic'),
      reason: '${result.stdout}\n${result.stderr}',
    );
  }

  void skipped(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 0 SQL variants; 0 failed; 1 dynamic'),
      reason: '${result.stdout}\n${result.stderr}',
    );
  }

  void bindings(ProcessResult result, {int count = 1, int skipped = 0}) {
    expect(
      result.stdout,
      contains(
        'Checked $count named parameter sets; 0 missing bindings; $skipped binding checks skipped.',
      ),
      reason: '${result.stdout}\n${result.stderr}',
    );
  }

  void missingBinding(ProcessResult result) {
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 1 SQL variants; 0 failed; 0 dynamic'),
    );
    expect(
      result.stdout,
      contains(
        'Checked 1 named parameter sets; 1 missing bindings; 0 binding checks skipped.',
      ),
      reason: '${result.stdout}\n${result.stderr}',
    );
  }

  final flags = List.generate(8, (index) => 'bool flag$index').join(', ');
  final irrelevantValues = List.generate(
    8,
    (index) => 'final noise$index = flag$index ? 1 : 2;',
  ).join(' ');
  final conditionalValues = List.generate(
    8,
    (index) => "'p$index': flag$index ? 1 : 2",
  ).join(', ');

  group('independent SQL literals', () {
    test(
      'literal SQL remains checkable after unknown runtime collection flow',
      () async {
        checked(
          await check(
            "void example(dynamic session, List<dynamic> rows) { for (final row in rows) consume(row); session.db.unsafeQuery('select 1'); }",
          ),
        );
      },
    );
    test(
      'adjacent literal SQL preserves diagnostics after unrelated flow',
      () async {
        final result = await check('''
void example(dynamic session, List<dynamic> rows) {
  for (final row in rows) consume(row);
  session.db.unsafeQuery('select ' 'from;');
}
''');
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Checked 1 SQL variants; 1 failed; 0 dynamic'),
        );
        expect(result.stderr, contains('FAIL endpoint.dart:3:'));
      },
    );
    test(
      'fresh fixed binding keys remain checkable after unrelated flow',
      () async {
        final result = await check(
          "void example(dynamic session, List<dynamic> rows, dynamic value) { for (final row in rows) consume(row); session.db.unsafeQuery('select @id', parameters: QueryParameters.named({'id': value})); }",
        );
        checked(result);
        bindings(result);
      },
    );
    test(
      'fresh binding keys do not depend on value effects on another map',
      () async {
        final result = await check(
          "int mutate(Map<String, Object?> previous) { consume(previous); return 1; } void example(dynamic session) { final previous = <String, Object?>{'other': 1}; session.db.unsafeQuery('select @id', parameters: QueryParameters.named({'id': mutate(previous)})); }",
        );
        checked(result);
        bindings(result);
      },
    );
    test(
      'fresh fixed keys still report a missing required parameter',
      () async {
        missingBinding(
          await check(
            "void example(dynamic session, List<dynamic> rows, dynamic value) { for (final row in rows) consume(row); session.db.unsafeQuery('select @id', parameters: QueryParameters.named({'other': value})); }",
          ),
        );
      },
    );
    for (final entry in <String, String>{
      'runtime map key': '{runtimeKey: 1}',
      'runtime map spread': '{...runtimeMap}',
      'conditional key': "{if (flag) 'id': 1}",
    }.entries) {
      test('${entry.key} cannot obtain a fixed binding certificate', () async {
        final result = await check(
          "void example(dynamic session, String runtimeKey, Map<String, Object?> runtimeMap, bool flag) { session.db.unsafeQuery('select @id', parameters: QueryParameters.named(${entry.value})); }",
        );
        checked(result);
        bindings(result, count: 0, skipped: 1);
      });
    }
  });

  group('SQL dependency slicing', () {
    test('unrelated numeric values do not multiply SQL paths', () async {
      checked(
        await check(
          "void example(dynamic session, $flags) { $irrelevantValues session.db.unsafeQuery('select 1'); }",
        ),
      );
    });
    test('unrelated helper returns do not multiply correlated binding paths', () async {
      final helpers = List.generate(
        8,
        (index) => 'final noise$index = number(flag$index);',
      ).join(' ');
      final result = await check(
        "int number(bool flag) { if (flag) return 1; return 2; } void example(dynamic session, bool active, $flags) { $helpers var sql = 'select 1'; final params = <String, Object?>{}; if (active) sql += ' where id = @id'; if (active) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
      );
      checked(result, count: 2);
      bindings(result);
    });
    test('needed local initializer dependencies retain both SQL paths', () async {
      checked(
        await check(
          "void example(dynamic session, bool flag, $flags) { $irrelevantValues final table = flag ? 'equipment' : 'locations'; final sql = 'select * from ' + table; session.db.unsafeQuery(sql); }",
        ),
        count: 2,
      );
    });
    test('a needed assignment retains its runtime dependency', () async {
      skipped(
        await check(
          "void example(dynamic session, String runtimeSql, $flags) { $irrelevantValues var sql = 'select 1'; sql = runtimeSql; session.db.unsafeQuery(sql); }",
        ),
      );
    });
    test('finite loop values remain dependencies of the selected SQL', () async {
      checked(
        await check(
          "void example(dynamic session, $flags) { $irrelevantValues final parts = <String>[]; for (final part in ['select', '1']) parts.add(part); session.db.unsafeQuery(parts.join(' ')); }",
        ),
      );
    });
    test('finite calls inside a loop retain their loop binding', () async {
      checked(
        await check(
          "void example(dynamic session, $flags) { $irrelevantValues for (final sql in ['select 1', 'select 2']) session.db.unsafeQuery(sql); }",
        ),
        count: 2,
      );
    });
    test('a conditional assignment keeps its condition initializer', () async {
      checked(
        await check(
          "void example(dynamic session, dynamic filters, $flags) { $irrelevantValues final active = filters.active; var sql = 'select 1'; if (active) sql += ' where true'; session.db.unsafeQuery(sql); }",
        ),
        count: 2,
      );
    });
    test('an early return condition still constrains a needed assignment', () async {
      checked(
        await check(
          "void example(dynamic session, bool flag, $flags) { $irrelevantValues if (flag) return; var sql = 'select 1'; if (flag) sql = 'select from;'; session.db.unsafeQuery(sql); }",
        ),
      );
    });
    test('local helper captures are retained transitively', () async {
      checked(
        await check(
          "void example(dynamic session, bool flag, $flags) { $irrelevantValues final table = flag ? 'equipment' : 'locations'; String inner() => 'select * from ' + table; String outer() => inner(); final sql = outer(); session.db.unsafeQuery(sql); }",
        ),
        count: 2,
      );
    });
    test('imported helper arguments retain caller dependencies', () async {
      File(p.join(fixture().path, 'queries.dart')).writeAsStringSync(
        "String query(String table) => 'select * from ' + table;",
      );
      checked(
        await check(
          "import 'queries.dart'; void example(dynamic session, bool flag, $flags) { $irrelevantValues final table = flag ? 'equipment' : 'locations'; final sql = query(table); session.db.unsafeQuery(sql); }",
        ),
        count: 2,
      );
    });
    test('a concrete method helper keeps receiver initializer dependencies', () async {
      checked(
        await check(
          "class Builder { final String table; Builder(this.table); String sql() => 'select * from ' + table; } void example(dynamic session, bool flag, $flags) { $irrelevantValues final table = flag ? 'equipment' : 'locations'; final builder = Builder(table); session.db.unsafeQuery(builder.sql()); }",
        ),
        count: 2,
      );
    });
  });

  group('binding keys are independent of unrelated values', () {
    test('local fixed-key map values do not exhaust the variant budget', () async {
      final result = await check(
        "void example(dynamic session, $flags) { final params = <String, Object?>{$conditionalValues}; session.db.unsafeQuery('select @p0', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result);
    });
    test('fixed keys survive a spread of another fixed-key map', () async {
      final result = await check(
        "void example(dynamic session, $flags) { final initial = <String, Object?>{$conditionalValues}; final params = <String, Object?>{...initial}; session.db.unsafeQuery('select @p0', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result);
    });
    test('fixed keys survive addAll without evaluating all value branches', () async {
      final result = await check(
        "void example(dynamic session, $flags) { final params = <String, Object?>{}; params.addAll(<String, Object?>{$conditionalValues}); session.db.unsafeQuery('select @p0', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result);
    });
    test('a conditional key stays correlated with conditional SQL', () async {
      final result = await check(
        "void example(dynamic session, bool active, $flags) { $irrelevantValues var sql = 'select 1'; if (active) sql += ' where id = @id'; final params = <String, Object?>{if (active) 'id': 1}; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
      );
      checked(result, count: 2);
      bindings(result);
    });
    test('computed binding key names remain demanded', () async {
      final result = await check(
        "void example(dynamic session, String runtimeKey, $flags) { $irrelevantValues final params = <String, Object?>{runtimeKey: 1}; session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
    test('map values used as SQL retain their complete alternatives', () async {
      final result = await check(
        "void example(dynamic session, bool flag, $flags) { $irrelevantValues final params = <String, Object?>{'sql': flag ? 'select 1' : 'select 2'}; session.db.unsafeQuery(params['sql'], parameters: QueryParameters.named(params)); }",
      );
      checked(result, count: 2);
    });
    test(
      'map values used as SQL cannot hide a malformed alternative',
      () async {
        final result = await check(
          "void example(dynamic session, bool flag) { final params = <String, Object?>{'sql': flag ? 'select 1' : 'select from;'}; session.db.unsafeQuery(params['sql'], parameters: QueryParameters.named(params)); }",
        );
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Checked 2 SQL variants; 1 failed; 0 dynamic'),
        );
      },
    );
  });

  group('private caller dependency slicing', () {
    test('unrelated caller values do not exhaust closed call contexts', () async {
      checked(
        await check(
          "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, bool flag, $flags) { $irrelevantValues final sql = flag ? 'select 1' : 'select 2'; _execute(session, sql); }",
        ),
        count: 2,
      );
    });
    test('caller slicing preserves SQL and parameter correlations', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session, bool active, $flags) { $irrelevantValues var sql = 'select 1'; final params = <String, Object?>{}; if (active) sql += ' where id = @id'; if (active) params['id'] = 1; _execute(session, sql, params); }",
      );
      checked(result, count: 2);
      bindings(result);
    });
    test('caller map argument values retain malformed SQL alternatives', () async {
      final result = await check(
        "void _execute(dynamic session, Map<String, String> query) { session.db.unsafeQuery(query['sql']); } void example(dynamic session, bool flag, $flags) { $irrelevantValues final query = <String, String>{'sql': flag ? 'select 1' : 'select from;'}; _execute(session, query); }",
      );
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stdout,
        contains('Checked 2 SQL variants; 1 failed; 0 dynamic'),
      );
    });
  });

  group('unused aliases still mutate demanded collections', () {
    final knownMutations = <String, String>{
      'direct alias': 'final alias = params; alias.clear();',
      'alias chain': 'final a = params; final alias = a; alias.clear();',
      'reassigned alias': "var alias = <String, Object?>{'other': 1}; alias = params; alias.clear();",
      'reassigned chain': "var a = <String, Object?>{'other': 1}; var b = a; a = params; b = a; b.clear();",
    };
    for (final entry in knownMutations.entries) {
      test(entry.key, () async {
        missingBinding(
          await check(
            "void example(dynamic session) { final params = <String, Object?>{'id': 1}; ${entry.value} session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
          ),
        );
      });
    }
    for (final entry in <String, String>{
      'record property alias': 'final holder = (params: params); final alias = holder.params; consume(alias);',
      'list index alias':
          'final holder = [params]; final alias = holder[0]; consume(alias);',
      'constructor field alias': 'final holder = Holder(params); final alias = holder.params; consume(alias);',
    }.entries) {
      test('escaping ${entry.key} invalidates original bindings', () async {
        final result = await check(
          "class Holder { final Map<String, Object?> params; Holder(this.params); } void example(dynamic session) { final params = <String, Object?>{'id': 1}; ${entry.value} session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
        );
        checked(result);
        bindings(result, count: 0, skipped: 1);
      });
    }
    test('runtime mutation through an unused alias is not discarded', () async {
      final result = await check(
        "void example(dynamic session) { final params = <String, Object?>{'id': 1}; final alias = params; consume(alias); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
    test(
      'a discarded list computation cannot prove a stale SQL element',
      () async {
        skipped(
          await check(
            "void example(dynamic session) { final parts = ['select 1']; final unused = consume(parts); session.db.unsafeQuery(parts[0]); }",
          ),
        );
      },
    );
  });

  group('key-only values preserve mutable aliases', () {
    test(
      'map literal values retain aliases to demanded SQL collections',
      () async {
        skipped(
          await check(
            "void example(dynamic session) { final parts = ['select 1']; final params = <String, Object?>{'payload': parts}; consume(params['payload']); session.db.unsafeQuery(parts[0], parameters: QueryParameters.named(params)); }",
          ),
        );
      },
    );
    test('map index assignment retains mutable value aliases', () async {
      skipped(
        await check(
          "void example(dynamic session) { final parts = ['select 1']; final params = <String, Object?>{}; params['payload'] = parts; consume(params['payload']); session.db.unsafeQuery(parts[0], parameters: QueryParameters.named(params)); }",
        ),
      );
    });
    test('a map spread retains mutable value aliases', () async {
      skipped(
        await check(
          "void example(dynamic session) { final parts = ['select 1']; final initial = <String, Object?>{'payload': parts}; final params = <String, Object?>{...initial}; consume(params['payload']); session.db.unsafeQuery(parts[0], parameters: QueryParameters.named(params)); }",
        ),
      );
    });
  });

  group('discarded values preserve unknown effects', () {
    test('a readable void helper preserves actual map mutation', () async {
      missingBinding(
        await check(
          "void mutate(Map<String, Object?> params) { params.clear(); } void example(dynamic session) { final params = <String, Object?>{'id': 1}; mutate(params); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
        ),
      );
    });
    for (final entry in <String, (String, String, String)>{
      'direct async helper': (
        'Future<void> mutate(Map<String, Object?> params) async { params.clear(); }',
        '',
        'mutate(params);',
      ),
      'awaited async helper': (
        'Future<void> mutate(Map<String, Object?> params) async { params.clear(); }',
        'async',
        'await mutate(params);',
      ),
      'recursive helper': (
        'void mutate(Map<String, Object?> params) { mutate(params); }',
        '',
        'mutate(params);',
      ),
      'helper schedules a mutating callback': (
        'void mutate(Map<String, Object?> params) { Future(() { params.clear(); }); }',
        '',
        'mutate(params);',
      ),
      'discarded async helper value': (
        'Future<void> mutate(Map<String, Object?> params) async { params.clear(); }',
        '',
        'final unused = mutate(params);',
      ),
      'helper wrapped in an unsupported type test': (
        'Object? mutate(Map<String, Object?> params) { params.clear(); return null; }',
        '',
        'mutate(params) is Object;',
      ),
    }.entries) {
      test('${entry.key} cannot certify stale binding keys', () async {
        final result = await check(
          "${entry.value.$1} void example(dynamic session) ${entry.value.$2} { final params = <String, Object?>{'id': 1}; ${entry.value.$3} session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
        );
        checked(result);
        bindings(result, count: 0, skipped: 1);
      });
    }
    test(
      'a helper wrapped in a cast retains actual argument effects',
      () async {
        missingBinding(
          await check(
            "Object? mutate(Map<String, Object?> params) { params.clear(); return null; } void example(dynamic session) { final params = <String, Object?>{'id': 1}; (mutate(params) as Object?); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
          ),
        );
      },
    );
    test('helper argument path limits invalidate mutable caller aliases', () async {
      final declarations = List.generate(
        6,
        (index) => 'int a$index',
      ).join(', ');
      final arguments = List.generate(
        6,
        (index) => 'flag$index ? 1 : 2',
      ).join(', ');
      final result = await check(
        "void mutate(Map<String, Object?> params, $declarations) { params.clear(); } void example(dynamic session, $flags) { final params = <String, Object?>{'id': 1}; mutate(params, $arguments); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
    test(
      'a discarded local helper return cannot retain stale captured SQL',
      () async {
        skipped(
          await check(
            "void example(dynamic session, String runtimeSql) { var sql = 'select 1'; int mutate() { sql = runtimeSql; return 0; } final unused = mutate(); session.db.unsafeQuery(sql); }",
          ),
        );
      },
    );
    test(
      'nested discarded helper calls cannot retain stale captured SQL',
      () async {
        skipped(
          await check(
            "void example(dynamic session, String runtimeSql) { var sql = 'select 1'; int inner() { sql = runtimeSql; return 0; } int outer() => inner(); final unused = outer(); session.db.unsafeQuery(sql); }",
          ),
        );
      },
    );
    test(
      'a discarded callback invocation cannot retain stale captured SQL',
      () async {
        skipped(
          await check(
            "void example(dynamic session, String runtimeSql) { var sql = 'select 1'; final callback = () { sql = runtimeSql; return 0; }; final unused = callback(); session.db.unsafeQuery(sql); }",
          ),
        );
      },
    );
    test('a discarded helper return cannot retain stale map keys', () async {
      final result = await check(
        "void example(dynamic session) { final params = <String, Object?>{'id': 1}; int mutate() { consume(params); return 0; } final unused = mutate(); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
    test('an unused getter can mutate a map through its receiver', () async {
      final result = await check(
        "class Holder { final Map<String, Object?> params; Holder(this.params); int get count { consume(params); return 0; } } void example(dynamic session) { final params = <String, Object?>{'id': 1}; final holder = Holder(params); final unused = holder.count; session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
    test('an unused overloaded operator can mutate a receiver map', () async {
      final result = await check(
        "class Holder { final Map<String, Object?> params; Holder(this.params); int operator +(int value) { consume(params); return value; } } void example(dynamic session) { final params = <String, Object?>{'id': 1}; final holder = Holder(params); final unused = holder + 1; session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
    test(
      'ignored parameter values cannot conceal captured SQL mutation',
      () async {
        skipped(
          await check(
            "void example(dynamic session, String runtimeSql) { var sql = 'select @id'; int mutate() { sql = runtimeSql; return 1; } final params = <String, Object?>{'id': mutate()}; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
          ),
        );
      },
    );
    test('ignored parameter values cannot conceal alias mutation', () async {
      final result = await check(
        "void example(dynamic session) { final params = <String, Object?>{'id': 1}; final extra = <String, Object?>{'noise': consume(params)}; params.addAll(extra); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
  });
}
