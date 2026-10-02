import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void finiteFlowTests(
  Directory Function() fixture,
  Future<ProcessResult> Function(Directory, List<String>) run,
) {
  Future<ProcessResult> check(String source, {int major = 17}) {
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

  void skipped(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 0 SQL variants; 0 failed; 1 dynamic'),
    );
  }

  group('finite string flow', () {
    final cases = <String, (String, int)>{
      'mutable initializer': ("var sql = 'select 1';", 1),
      'assignment replaces initializer': (
        "var sql = 'invalid'; sql = 'select 1';",
        1,
      ),
      'uninitialized then assigned': ("String sql; sql = 'select 1';", 1),
      'conditional append': (
        "var sql = 'select 1'; if (flag) sql += ' where true';",
        2,
      ),
      'self concatenation': (
        "var sql = 'select 1'; sql = sql + ' where true';",
        1,
      ),
      'if else': (
        "var sql = 'invalid'; if (flag) sql = 'select 1'; else sql = 'select 2';",
        2,
      ),
      'known condition': (
        "var sql = 'select 1'; if (false) sql = dynamicSql;",
        1,
      ),
      'nested branches': (
        "var sql = 'select 1'; if (flag) { if (other) sql += ' where true'; else sql += ' where false'; }",
        3,
      ),
      'unrelated statements': (
        "var sql = 'select 1'; logSomething(); final other = load();",
        1,
      ),
      'scope shadowing': (
        "var sql = 'select 1'; { var sql = 'invalid'; sql = dynamicSql; }",
        1,
      ),
      'terminating branch': (
        "var sql = 'select 1'; if (flag) { sql = dynamicSql; return; }",
        1,
      ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        checked(
          await check(
            'void example(dynamic session, bool flag, bool other, String dynamicSql) { ${entry.value.$1} session.db.unsafeQuery(sql); }',
          ),
          count: entry.value.$2,
        );
      });
    }
    test('snapshot is taken at each use', () async {
      checked(
        await check(
          "void example(dynamic session) { var sql = 'select 1'; final saved = sql; sql = 'select from;'; session.db.unsafeQuery(saved); session.db.unsafeQuery(sql); }",
        ),
        count: 2,
        failures: 1,
      );
    });
    test('mutations after the call do not change its value', () async {
      checked(
        await check(
          "void example(dynamic session, String runtimeSql) { var sql = 'select 1'; session.db.unsafeQuery(sql); sql = runtimeSql; }",
        ),
      );
    });
    test('use inside a selected branch', () async {
      checked(
        await check(
          "void example(dynamic session, bool flag) { var sql = 'invalid'; if (flag) { sql = 'select 1'; session.db.unsafeQuery(sql); } }",
        ),
      );
    });
    test('an unreadable branch skips the whole query', () async {
      skipped(
        await check(
          "void example(dynamic session, bool flag, String runtimeSql) { var sql = 'select 1'; if (flag) sql += runtimeSql; session.db.unsafeQuery(sql); }",
        ),
      );
    });
    test(
      'if-case patterns are not interpreted as boolean conditions',
      () async {
        checked(
          await check(
            "void example(dynamic session) { var sql = 'select 1'; if (false case false) sql = 'select from;'; session.db.unsafeQuery(sql); }",
          ),
          count: 2,
          failures: 1,
        );
      },
    );
    for (final entry in <String, String>{
      'loop write': "var sql = 'select 1'; for (final item in items) sql += item; session.db.unsafeQuery(sql);",
      'call in loop': "var sql = 'select 1'; for (final item in items) { session.db.unsafeQuery(sql); sql += item; }",
      'closure mutation': "var sql = 'select 1'; void change() { sql = runtimeSql; } change(); session.db.unsafeQuery(sql);",
      'mutation in condition': "var sql = 'select 1'; if ((sql = runtimeSql).isEmpty) {} session.db.unsafeQuery(sql);",
      'unknown assignment': "var sql = 'select 1'; sql = runtimeSql; session.db.unsafeQuery(sql);",
    }.entries) {
      test('${entry.key} remains unknown', () async {
        skipped(
          await check(
            'void example(dynamic session, List<String> items, String runtimeSql) { ${entry.value} }',
          ),
        );
      });
    }
    test('branch expansion remains bounded', () async {
      final updates = [
        for (var i = 0; i < 6; i++) "if (flags[$i]) sql += ' + $i';",
      ].join(' ');
      skipped(
        await check(
          "void example(dynamic session, List<bool> flags) { var sql = 'select 1'; $updates session.db.unsafeQuery(sql); }",
        ),
      );
    });
    for (final major in [17, 18]) {
      test('mutable PL/pgSQL retains source diagnostics on $major', () async {
        final result = await check(
          r'''void example(dynamic session, bool flag) {
  var sql = r'do $$ BEGIN NULL; END; $$;';
  if (flag) sql = r'do $$ BEGIN IF THEN END IF; END; $$;';
  session.db.unsafeExecute(sql);
}''',
          major: major,
        );
        checked(result, count: 2, failures: 1);
        expect(result.stderr, contains('FAIL endpoint.dart:3:'));
        expect(result.stderr, contains('PL/pgSQL:'));
      });
    }
  });

  group('switch strings', () {
    test('all readable cases and guards are checked', () async {
      checked(
        await check(
          "void example(dynamic session, int choice) { final sql = switch (choice) { 0 when choice.isEven => 'select 1', 1 => 'select 2', _ => 'select from;' }; session.db.unsafeQuery(sql); }",
        ),
        count: 3,
        failures: 1,
      );
    });
    test('interpolated switch fragments', () async {
      checked(
        await check(
          r"void example(dynamic session, int choice) { final clause = switch (choice) { 0 => 'where true', _ => 'where false' }; session.db.unsafeQuery('select 1 $clause'); }",
        ),
        count: 2,
      );
    });
    test('pattern-bound runtime strings stay unknown', () async {
      skipped(
        await check(
          "void example(dynamic session, Object choice) { final sql = switch (choice) { String sql => sql, _ => 'select 1' }; session.db.unsafeQuery(sql); }",
        ),
      );
    });
    test('unknown case invalidates all cases', () async {
      skipped(
        await check(
          "void example(dynamic session, int choice, String runtimeSql) { final sql = switch (choice) { 0 => 'select 1', _ => runtimeSql }; session.db.unsafeQuery(sql); }",
        ),
      );
    });
    test('switch helper returns', () async {
      checked(
        await check(
          "String build(int choice) => switch (choice) { 0 => 'select 1', _ => 'select 2' }; void example(dynamic session, int choice) { session.db.unsafeQuery(build(choice)); }",
        ),
        count: 2,
      );
    });
    test('helper if-case patterns retain both return branches', () async {
      checked(
        await check(
          "String build() { if (false case false) return 'select from;'; return 'select 1'; } void example(dynamic session) { session.db.unsafeQuery(build()); }",
        ),
        count: 2,
        failures: 1,
      );
    });
    test('switch expansion is bounded', () async {
      final cases = [for (var i = 0; i < 32; i++) "$i => 'select $i',"]
          .join(' ');
      skipped(
        await check(
          "void example(dynamic session, int choice) { session.db.unsafeQuery(switch (choice) { $cases _ => 'select 32' }); }",
        ),
      );
    });
  });

  group('CTE prefix templates', () {
    test('a composed trailing comma is a fragment', () async {
      final result = await check(r'''class Queries {
  String _cte() => 'WI' + 'TH example AS (SELECT 1)';
  void example(dynamic session) { final ctePrefix = '${_cte()},'; }
}''');
      checked(result);
      expect(result.stdout, contains('(CTE fragment)'));
    });
    test('a bare WITH branch is a fragment', () async {
      checked(
        await check(r'''void example(dynamic session, bool flag) {
  final ctePrefix = 'WITH${flag ? ' example AS (SELECT 1),' : ''}';
}'''),
        count: 2,
      );
    });
    test('raw query calls require a complete query', () async {
      checked(
        await check(
          "void example(dynamic session) { session.db.unsafeQuery('WITH example AS (SELECT 1),'); }",
        ),
        failures: 1,
      );
    });
    test('invalid CTE contents still fail', () async {
      checked(
        await check(
          "void example(dynamic session) { final ctePrefix = 'WITH example AS (SELECT FROM),'; }",
        ),
        failures: 1,
      );
    });
  });

  group('instance helper dispatch', () {
    for (final call in ['_build(flag)', 'this._build(flag)']) {
      test(call, () async {
        checked(
          await check(
            "class Endpoint extends UnknownBase { String _build(bool flag) { if (flag) return 'select 1'; return 'select 2'; } void example(dynamic session, bool flag) { session.db.unsafeQuery($call); } }",
          ),
          count: 2,
        );
      });
    }
    test('private helper string arguments', () async {
      checked(
        await check(r'''class Queries {
  String _build(String table) => 'select * from $table';
  void example(dynamic session) { session.db.unsafeQuery(_build('equipment')); }
}'''),
      );
    });
    test('private helper chains', () async {
      checked(
        await check(
          "class Queries { String _fragment() => 'select 1'; String _build() => this._fragment(); void example(dynamic session) { session.db.unsafeQuery(_build()); } }",
        ),
      );
    });
    test('private immutable fields can supply helper strings', () async {
      checked(
        await check(
          "class Queries { final _sql = 'select 1'; String _build() => _sql; void example(dynamic session) { session.db.unsafeQuery(_build()); } }",
        ),
      );
    });
    test('public helper on final class', () async {
      checked(
        await check(
          "final class Queries { String build() => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(build()); } }",
        ),
      );
    });
    for (final entry in <String, String>{
      'overridable public method': "class Queries { String build() => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(build()); } }",
      'private override in library': "class Queries { String _build() => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(_build()); } } class Other extends Queries { String _build() => runtimeSql; }",
      'override of final class in library': "final class Queries { String build() => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(build()); } } final class Other extends Queries { String build() => runtimeSql; }",
      'mixin override on a final subclass': "final class Queries { String build() => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(build()); } } final class Other extends Queries with UnknownMixin {}",
      'parts may override': "part 'other.dart'; class Queries { String _build() => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(_build()); } }",
      'instance getter state': "class Queries { String get sql => runtimeSql; String _build() => sql; void example(dynamic session) { session.db.unsafeQuery(_build()); } }",
      'public field may be overridden': "class Queries { final sql = 'select 1'; String _build() => sql; void example(dynamic session) { session.db.unsafeQuery(_build()); } }",
    }.entries) {
      test('${entry.key} stays unknown', () async {
        skipped(await check(entry.value));
      });
    }
  });

  group('finite parameter maps', () {
    Future<ProcessResult> mapCheck(
      String setup,
      String sql,
      String map,
    ) => check(
      'void example(dynamic session, bool flag, Map<String, Object?> extras) { $setup session.db.unsafeQuery(\'$sql\', parameters: QueryParameters.named($map)); }',
    );
    for (final entry in <String, (String, String)>{
      'local map': ("final params = {'id': 1};", 'params'),
      'static spread': ("const base = {'id': 1};", "{...base}"),
      'spread makes an independent copy': (
        "final base = {'id': 1}; final params = {...base}; base.clear();",
        'params',
      ),
      'constant map alias': (
        "const base = {'id': 1}; final params = base;",
        'params',
      ),
      'conditional unrelated key': ('', "{'id': 1, if (flag) 'unused': 2}"),
      'key in both branches': ('', "{if (flag) 'id': 1 else 'id': 2}"),
      'known branch': ('', "{if (true) 'id': 1}"),
      'null-aware null spread': ('', "{'id': 1, ...?null}"),
      'subscript addition': (
        "final params = <String, Object?>{}; params['id'] = loadId();",
        'params',
      ),
      'addAll': (
        "final params = <String, Object?>{}; params.addAll({'id': loadId()});",
        'params',
      ),
      'conditional additions in both branches': (
        "final params = <String, Object?>{}; if (flag) params['id'] = 1; else params.addAll({'id': 2});",
        'params',
      ),
      'unrelated conditional mutation': (
        "final params = {'id': 1}; if (flag) params['unused'] = 2;",
        'params',
      ),
      'map replacement': (
        "var params = {'wrong': 1}; params = {'id': 2};",
        'params',
      ),
      'clear and refill': (
        "final params = {'wrong': 1}; params.clear(); params['id'] = 2;",
        'params',
      ),
    }.entries) {
      test(entry.key, () async {
        final result = await mapCheck(
          entry.value.$1,
          'select @id',
          entry.value.$2,
        );
        checked(result);
        expect(
          result.stdout,
          contains(
            'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
          ),
        );
      });
    }
    test('conditional matching key remains uncertain', () async {
      final result = await mapCheck('', 'select @id', "{if (flag) 'id': 1}");
      checked(result);
      expect(
        result.stdout,
        contains('0 missing bindings; 1 binding checks skipped.'),
      );
    });
    test(
      'definitely missing keys still fail beside conditional keys',
      () async {
        final result = await mapCheck(
          '',
          'select @id, @missing',
          "{if (flag) 'id': 1}",
        );
        expect(result.exitCode, 1);
        expect(
          result.stderr,
          contains('missing named parameter binding for @missing'),
        );
        expect(result.stderr, isNot(contains('binding for @id')));
      },
    );
    test('remove makes a binding definitely missing', () async {
      final result = await mapCheck(
        "final params = {'id': 1}; params.remove('id');",
        'select @id',
        'params',
      );
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
    for (final entry in <String, (String, String)>{
      'clear through alias': (
        "final params = {'id': 1}; final alias = params; alias.clear();",
        'params',
      ),
      'alias retains another map': (
        "final base = {'id': 1}; final params = base; base.clear();",
        'params',
      ),
      'conditional initializer retains aliases': (
        "final base = {'id': 1}; final params = flag ? base : <String, Object?>{}; base.clear();",
        'params',
      ),
      'replacement retains an alias': (
        "final base = {'id': 1}; var params = <String, Object?>{}; params = base; base.clear();",
        'params',
      ),
    }.entries) {
      test('${entry.key} identifies missing bindings', () async {
        final result = await mapCheck(
          entry.value.$1,
          'select @id',
          entry.value.$2,
        );
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stderr,
          contains('missing named parameter binding for @id'),
        );
        expect(
          result.stdout,
          contains('1 missing bindings; 0 binding checks skipped.'),
        );
      });
    }
    for (final entry in <String, (String, String)>{
      'runtime spread': ('', "{'id': 1, ...extras}"),
      'escape through call': (
        "final params = {'id': 1}; change(params);",
        'params',
      ),
      'captured map': (
        "final params = {'id': 1}; void change() { params.clear(); } change();",
        'params',
      ),
      'loop mutation': (
        "final params = {'id': 1}; while (flag) params.clear();",
        'params',
      ),
      'unknown mutation': (
        "final params = {'id': 1}; params.removeWhere((key, value) => flag);",
        'params',
      ),
      'mutating value': (
        "final params = {'id': 1}; params['id'] = mutate(params);",
        'params',
      ),
      'mutating spread value': (
        "final params = {'id': 1}; params.addAll({'id': mutate(params)});",
        'params',
      ),
    }.entries) {
      test('${entry.key} remains uncertain', () async {
        final result = await mapCheck(
          entry.value.$1,
          'select @id',
          entry.value.$2,
        );
        checked(result);
        expect(
          result.stdout,
          contains('0 missing bindings; 1 binding checks skipped.'),
        );
      });
    }
    test('SQL and map paths share the same local condition', () async {
      final result = await check(r'''void example(dynamic session, bool flag) {
  var clause = '';
  final params = <String, Object?>{};
  if (flag) { clause = 'where id = @id'; params['id'] = 1; }
  session.db.unsafeQuery('select 1 $clause', parameters: QueryParameters.named(params));
}''');
      checked(result, count: 2);
      expect(
        result.stdout,
        contains(
          'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
        ),
      );
    });
  });
}
