import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Query arguments inferred from complete, readable private call sites.
void staticContextTests(
  Directory Function() fixture,
  Future<ProcessResult> Function(Directory, List<String>) run,
) {
  Future<ProcessResult> check(String source, {int major = 17}) {
    expect(
      parseString(content: source, throwIfDiagnostics: false).errors,
      isEmpty,
      reason: 'The fixture must contain syntactically valid Dart:\n$source',
    );
    final file = File(p.join(fixture().path, 'endpoint.dart'));
    file.writeAsStringSync(source);
    return run(fixture(), [
      '--root=${fixture().path}',
      '--verbose',
      '--postgres-version=$major',
      file.path,
    ]);
  }

  void checked(ProcessResult result, {int count = 1, int failures = 0}) {
    expect(
      result.exitCode,
      failures == 0 ? 0 : 1,
      reason: '${result.stdout}\n${result.stderr}',
    );
    expect(
      result.stdout,
      contains('Checked $count SQL variants; $failures failed; 0 dynamic'),
    );
  }

  void skipped(ProcessResult result, {int count = 1}) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 0 SQL variants; 0 failed; $count dynamic'),
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

  group('private SQL call contexts', () {
    final cases = <String, (String, int)>{
      'private top-level positional argument': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); }",
        1,
      ),
      'all private calls contribute variants': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); _execute(session, 'select 2'); }",
        2,
      ),
      'named argument': (
        "void _execute(dynamic session, {required String sql}) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, sql: 'select 1'); }",
        1,
      ),
      'named default': (
        "void _execute(dynamic session, {String sql = 'select 1'}) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session); }",
        1,
      ),
      'optional positional default': (
        "void _execute(dynamic session, [String sql = 'select 1']) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session); }",
        1,
      ),
      'caller assignment flow': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { var sql = 'invalid'; sql = 'select 1'; _execute(session, sql); }",
        1,
      ),
      'caller conditional flow': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, bool flag) { var sql = 'select 1'; if (flag) sql = 'select 2'; _execute(session, sql); }",
        2,
      ),
      'later caller assignment does not alter prior context': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, String runtimeSql) { var sql = 'select 1'; _execute(session, sql); sql = runtimeSql; }",
        1,
      ),
      'caller finite loop contexts': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { for (final sql in ['select 1', 'select 2']) _execute(session, sql); }",
        2,
      ),
      'local function positional argument': (
        "void example(dynamic session) { void execute(String sql) { session.db.unsafeQuery(sql); } execute('select 1'); }",
        1,
      ),
      'local function named default': (
        "void example(dynamic session) { void execute({String sql = 'select 1'}) { session.db.unsafeQuery(sql); } execute(); }",
        1,
      ),
      'unique private instance method': (
        "class Endpoint { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); } }",
        1,
      ),
      'explicit this private method': (
        "class Endpoint { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { this._execute(session, 'select 1'); } }",
        1,
      ),
      'unique private static method': (
        "class Queries { static void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } } void example(dynamic session) { Queries._execute(session, 'select 1'); }",
        1,
      ),
      'nested private callers': (
        r"void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void _table(dynamic session, String table) { _execute(session, 'select * from $table'); } void example(dynamic session) { _table(session, 'equipment'); }",
        1,
      ),
      'helper flow after supplied arguments': (
        "void _execute(dynamic session, String base, bool flag) { var sql = base; if (flag) sql += ' where true'; session.db.unsafeQuery(sql); } void example(dynamic session, bool flag) { _execute(session, 'select 1', flag); }",
        2,
      ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        checked(await check(entry.value.$1), count: entry.value.$2);
      });
    }
    test('a bad SQL variant from any call is reported', () async {
      checked(
        await check(
          "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); _execute(session, 'select from;'); }",
        ),
        count: 2,
        failures: 1,
      );
    });
    test('imported static SQL is bound at the private call', () async {
      File(p.join(fixture().path, 'queries.dart'))
          .writeAsStringSync("const equipmentSql = 'select * from equipment';");
      checked(
        await check(
          "import 'queries.dart'; void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, equipmentSql); }",
        ),
      );
    });
  });

  group('private SQL and binding contexts', () {
    test('fixed binding keys do not depend on runtime value branches', () async {
      final values = List.generate(
        8,
        (index) => "'p$index': flag$index ? readA() : readB()",
      ).join(', ');
      final flags = List.generate(8, (index) => 'bool flag$index').join(', ');
      final result = await check(
        "void example(dynamic session, $flags) { session.db.unsafeQuery('select @p0', parameters: QueryParameters.named({$values})); }",
      );
      checked(result);
      bindings(result);
    });
    test('maps passed alongside SQL retain readable keys', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session) { _execute(session, 'select @id', {'id': loadId()}); }",
      );
      checked(result);
      bindings(result);
    });
    test('named SQL and parameter defaults', () async {
      final result = await check(
        "void _execute(dynamic session, {String sql = 'select @id', Map<String, Object?> params = const {'id': 1}}) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session) { _execute(session); }",
      );
      checked(result);
      bindings(result);
    });
    test('record contexts keep SQL and parameters paired', () async {
      final result = await check(
        "void _execute(dynamic session, dynamic statement) { session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.params)); } void example(dynamic session, bool flag) { final statement = flag ? (text: 'select @a', params: {'a': 1}) : (text: 'select @b', params: {'b': 2}); _execute(session, statement); }",
      );
      checked(result, count: 2);
      bindings(result, count: 2);
    });
    test('object contexts keep SQL and parameters paired', () async {
      final result = await check(
        "class Statement { final String text; final Map<String, Object?> params; Statement(this.text, this.params); } void _execute(dynamic session, Statement statement) { session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.params)); } void example(dynamic session, bool flag) { final statement = flag ? Statement('select @a', {'a': 1}) : Statement('select @b', {'b': 2}); _execute(session, statement); }",
      );
      checked(result, count: 2);
      bindings(result, count: 2);
    });
    test('caller conditions keep SQL additions and keys paired', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session, bool flag) { var sql = 'select 1'; final params = <String, Object?>{}; if (flag) { sql += ' where id = @id'; params['id'] = 1; } _execute(session, sql, params); }",
      );
      checked(result, count: 2);
      bindings(result);
    });
    test('mutated caller map does not preserve stale keys', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session) { final params = {'id': 1}; params.clear(); _execute(session, 'select @id', params); }",
      );
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
    test(
      'later caller map mutations do not change earlier query keys',
      () async {
        final result = await check(
          "void _execute(dynamic session, String sql, Map<String, Object?> params) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session) { final params = {'id': 1}; _execute(session, 'select @id', params); params.clear(); }",
        );
        checked(result);
        bindings(result);
      },
    );
    test('an escaped caller map leaves binding checks unknown', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session) { final params = {'id': 1}; mutate(params); _execute(session, 'select @id', params); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
  });

  group('private context inference safeguards', () {
    final cases = <String, (String, int)>{
      'one unreadable call invalidates complete SQL coverage': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, String runtimeSql) { _execute(session, 'select 1'); _execute(session, runtimeSql); }",
        1,
      ),
      'private top-level tearoff': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); register(_execute); }",
        1,
      ),
      'local function tearoff': (
        "void example(dynamic session) { void execute(String sql) { session.db.unsafeQuery(sql); } execute('select 1'); register(execute); }",
        1,
      ),
      'private method tearoff': (
        "class Endpoint { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); register(_execute); } }",
        1,
      ),
      'recursive private calls': (
        "void _execute(dynamic session, String sql) { _execute(session, sql); session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); }",
        1,
      ),
      'competing private method selectors': (
        "class First { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } } class Second { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } } void example(dynamic session) { First()._execute(session, 'select 1'); Second()._execute(session, 'select 2'); }",
        2,
      ),
      'public top-level arguments remain open': (
        "void execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { execute(session, 'select 1'); }",
        1,
      ),
      'public instance method arguments remain open': (
        "class Endpoint { void execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { execute(session, 'select 1'); } }",
        1,
      ),
      'external callback context remains open': (
        "void example(dynamic session) { void execute(String sql) { session.db.unsafeQuery(sql); } register((String runtimeSql) => execute(runtimeSql)); execute('select 1'); }",
        1,
      ),
      'async runtime reassignment before the query': (
        "Future<void> _execute(dynamic session, String sql) async { sql = await loadSql(); session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); }",
        1,
      ),
      'private method in a library with parts': (
        "part 'more.dart'; class Endpoint { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); } }",
        1,
      ),
      'local shadow does not inherit a private function context': (
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, dynamic callback) { final _execute = callback; _execute(session, 'select 1'); }",
        1,
      ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        skipped(await check(entry.value.$1), count: entry.value.$2);
      });
    }
  });

  group('private context completeness regressions', () {
    final unknown = <String, String>{
      'qualified instance method tearoff': "class Endpoint { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session) { _execute(session, 'select 1'); register(this._execute); } }",
      'qualified static method tearoff': "class Queries { static void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } } void example(dynamic session) { Queries._execute(session, 'select 1'); register(Queries._execute); }",
      'private function forwarded through an alias': "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, String runtimeSql) { _execute(session, 'select 1'); final callback = _execute; callback(session, runtimeSql); }",
      'local function forwarded through an alias': "void example(dynamic session, String runtimeSql) { void execute(String sql) { session.db.unsafeQuery(sql); } execute('select 1'); final callback = execute; callback(runtimeSql); }",
      'unresolved private selector adds a possible unknown call': "class Endpoint { void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, dynamic other, String runtimeSql) { _execute(session, 'select 1'); other._execute(session, runtimeSql); } }",
      'mutually recursive private contexts': "void _first(dynamic session, String sql) { _second(session, sql); session.db.unsafeQuery(sql); } void _second(dynamic session, String sql) { _first(session, sql); } void example(dynamic session) { _first(session, 'select 1'); }",
      'external closure observes a later mutable captured SQL value': "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, String runtimeSql) { var sql = 'select 1'; register(() => _execute(session, sql)); sql = runtimeSql; }",
      'external closure observes a later local function capture': "void example(dynamic session, String runtimeSql) { var sql = 'select 1'; void execute(String value) { session.db.unsafeQuery(value); } register(() => execute(sql)); sql = runtimeSql; }",
      'external closure mutates SQL before calling a private function': "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, String runtimeSql) { var sql = 'select 1'; register(() { sql = runtimeSql; _execute(session, sql); }); }",
      'default receiver cannot invent a constructor supplied field': r"class Endpoint { final String prefix; Endpoint(this.prefix); void _execute(dynamic session, String tail) { session.db.unsafeQuery('$prefix $tail'); } void example(dynamic session) { _execute(session, '1'); } }",
      'default receiver cannot trust an overridden public field': r"class Endpoint { final String prefix = 'select'; void _execute(dynamic session, String tail) { session.db.unsafeQuery('$prefix $tail'); } void example(dynamic session) { _execute(session, '1'); } } class OtherEndpoint extends Endpoint { String get prefix => runtimePrefix; }",
    };
    for (final entry in unknown.entries) {
      test(entry.key, () async {
        skipped(await check(entry.value));
      });
    }
    test(
      'caller snapshots are preserved after later scalar reassignment',
      () async {
        checked(
          await check(
            "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); } void example(dynamic session, String runtimeSql) { var sql = 'select 1'; final saved = sql; sql = runtimeSql; _execute(session, saved); }",
          ),
        );
      },
    );
    test('a branch-selected map alias stays paired with its SQL', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session, bool flag) { var sql = 'select @a'; var params = {'a': 1}; if (flag) { sql = 'select @b'; params = {'b': 2}; } final alias = params; _execute(session, sql, alias); }",
      );
      checked(result, count: 2);
      bindings(result, count: 2);
    });
    test('callee mutation clears the provided map before the query', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { params.clear(); session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session) { _execute(session, 'select @id', {'id': 1}); }",
      );
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
    test('callee unknown escape leaves the provided map unreadable', () async {
      final result = await check(
        "void _execute(dynamic session, String sql, Map<String, Object?> params) { mutate(params); session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); } void example(dynamic session) { _execute(session, 'select @id', {'id': 1}); }",
      );
      checked(result);
      bindings(result, count: 0, skipped: 1);
    });
    test(
      'default receiver retains safe immutable private field values',
      () async {
        checked(
          await check(
            r"class Endpoint { final String _prefix = 'select'; void _execute(dynamic session, String tail) { session.db.unsafeQuery('$_prefix $tail'); } void example(dynamic session) { _execute(session, '1'); } }",
          ),
        );
      },
    );
  });

  group('private query context origins and PL/pgSQL', () {
    test('Unicode failure points to the supplied source string', () async {
      final result = await check(
        "void _execute(dynamic session, String sql) { session.db.unsafeQuery(sql); }\nvoid example(dynamic session) {\n  _execute(session, 'select é, from;');\n}",
      );
      checked(result, failures: 1);
      expect(result.stderr, contains('FAIL endpoint.dart:3:'));
    });
    for (final major in [17, 18]) {
      test(
        'private context parses complete procedural SQL on $major',
        () async {
          final result = await check(
            r"void _execute(dynamic session, String sql) { session.db.unsafeExecute(sql); } void example(dynamic session) { _execute(session, r'do $body$ BEGIN NULL; END; $body$;'); }",
            major: major,
          );
          checked(result);
          expect(
            result.stdout,
            contains('Checked 1 PL/pgSQL definitions; 0 failed.'),
          );
        },
      );
      test(
        'private context reports malformed procedural bodies on $major',
        () async {
          final result = await check(
            r"void _execute(dynamic session, String sql) { session.db.unsafeExecute(sql); } void example(dynamic session) { _execute(session, r'do $body$ BEGIN IF THEN END IF; END; $body$;'); }",
            major: major,
          );
          checked(result, failures: 1);
          expect(result.stderr, contains('PL/pgSQL:'));
        },
      );
    }
  });
}
