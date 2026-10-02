import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end tests for readable query builders, using the shared CLI bundle.
void staticAssemblyTests(
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

  void skipped(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 0 SQL variants; 0 failed; 1 dynamic'),
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

  group('static query objects and records', () {
    final objects = <String, String>{
      'positional final fields': "class Statement { final String text; final Map<String, Object?> parameters; const Statement(this.text, this.parameters); } void example(dynamic session) { final statement = Statement('select @id', {'id': loadId()}); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'named final fields': "class Statement { final String text; final Map<String, Object?> parameters; const Statement({required this.text, required this.parameters}); } void example(dynamic session) { final statement = Statement(text: 'select @id', parameters: {'id': loadId()}); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'constructor initializer fields': "class Statement { final String text; final Map<String, Object?> parameters; Statement(String sql, Map<String, Object?> args) : text = sql, parameters = args; } void example(dynamic session) { final statement = Statement('select @id', {'id': loadId()}); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'constructor default arguments': "class Statement { final String text; final Map<String, Object?> parameters; const Statement({this.text = 'select @id', this.parameters = const {'id': 1}}); } void example(dynamic session) { final statement = Statement(); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'declaration initialized fields': "class Statement { final text = 'select @id'; final parameters = const {'id': 1}; } void example(dynamic session) { final statement = Statement(); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'named record projections': "void example(dynamic session) { final statement = (text: 'select @id', parameters: {'id': loadId()}); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'positional record projections': r"void example(dynamic session) { final statement = ('select @id', {'id': loadId()}); session.db.unsafeQuery(statement.$1, parameters: QueryParameters.named(statement.$2)); }",
      'nested projections': "class Statement { final String text; final Map<String, Object?> parameters; const Statement(this.text, this.parameters); } void example(dynamic session) { final holder = (statement: Statement('select @id', {'id': loadId()}),); session.db.unsafeQuery(holder.statement.text, parameters: QueryParameters.named(holder.statement.parameters)); }",
      'helper returns object': "class Statement { final String text; final Map<String, Object?> parameters; const Statement(this.text, this.parameters); } Statement build() => Statement('select @id', {'id': loadId()}); void example(dynamic session) { final statement = build(); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'helper returns record': "({String text, Map<String, Object?> parameters}) build() => (text: 'select @id', parameters: {'id': loadId()}); void example(dynamic session) { final statement = build(); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'helper binds constructor string argument': r"class Statement { final String text; final Map<String, Object?> parameters; const Statement(this.text, this.parameters); } Statement build(String table) => Statement('select * from $table where id = @id', {'id': loadId()}); void example(dynamic session) { final statement = build('equipment'); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      'prebuilt QueryParameters field': "class Statement { final String text; final dynamic parameters; Statement(this.text, this.parameters); } void example(dynamic session) { final statement = Statement('select @id', QueryParameters.named({'id': loadId()})); session.db.unsafeQuery(statement.text, parameters: statement.parameters); }",
    };
    for (final entry in objects.entries) {
      test(entry.key, () async {
        final result = await check(entry.value);
        checked(result);
        bindings(result);
      });
    }
    test('record branch keeps text and bindings together', () async {
      final result = await check(
        "dynamic build(bool flag) { if (flag) return (text: 'select @a', parameters: {'a': 1}); return (text: 'select @b', parameters: {'b': 2}); } void example(dynamic session, bool flag) { final statement = build(flag); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      );
      checked(result, count: 2);
      bindings(result, count: 2);
    });
    test('known concrete receiver methods bind fields', () async {
      checked(
        await check(
          r"class Builder { final String table; Builder(this.table); String build() => 'select * from $table'; } void example(dynamic session) { final builder = Builder('equipment'); session.db.unsafeQuery(builder.build()); }",
        ),
      );
    });
    test('known concrete receiver chains', () async {
      checked(
        await check(
          r"class Builder { final String table; Builder(this.table); String fragment() => 'from $table'; String build() => 'select * ${fragment()}'; } void example(dynamic session) { session.db.unsafeQuery(Builder('equipment').build()); }",
        ),
      );
    });
    test('concrete receiver chooses its own override', () async {
      checked(
        await check(
          "class Builder { String build() => 'select from;'; } class Other extends Builder { String build() => 'select 1'; } void example(dynamic session) { final builder = Builder(); session.db.unsafeQuery(builder.build()); }",
        ),
        failures: 1,
      );
    });
    test(
      'implicit public final field may be overridden by a subclass',
      () async {
        skipped(
          await check(
            "class Builder { final String sql = 'select 1'; void example(dynamic session) { session.db.unsafeQuery(sql); } } class RuntimeBuilder extends Builder { String get sql => runtimeSql; }",
          ),
        );
      },
    );
    test(
      'implicit private immutable field remains readable without overrides',
      () async {
        checked(
          await check(
            "class Builder { final String _sql = 'select 1'; void example(dynamic session) { session.db.unsafeQuery(_sql); } } class OtherBuilder extends Builder { String get sql => runtimeSql; }",
          ),
        );
      },
    );
    test('missing binding through final fields is reported', () async {
      final result = await check(
        "class Statement { final String text; final Map<String, Object?> parameters; const Statement(this.text, this.parameters); } void example(dynamic session) { final statement = Statement('select @missing', {'id': 1}); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      );
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('missing named parameter binding for @missing'),
      );
    });
    test(
      'constructor string fields capture the value at construction',
      () async {
        checked(
          await check(
            "class Statement { final String text; Statement(this.text); } void example(dynamic session, String runtimeSql) { var text = 'select 1'; final statement = Statement(text); text = runtimeSql; session.db.unsafeQuery(statement.text); }",
          ),
        );
      },
    );
    test('constructor parameter fields retain mutable map identity', () async {
      final result = await check(
        "class Statement { final String text; final Map<String, Object?> parameters; Statement(this.text, this.parameters); } void example(dynamic session) { final params = {'id': 1}; final statement = Statement('select @id', params); params.clear(); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); }",
      );
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
    test('later parameter mutation does not alter an earlier call', () async {
      final result = await check(
        "class Statement { final String text; final Map<String, Object?> parameters; Statement(this.text, this.parameters); } void example(dynamic session) { final params = {'id': 1}; final statement = Statement('select @id', params); session.db.unsafeQuery(statement.text, parameters: QueryParameters.named(statement.parameters)); params.clear(); }",
      );
      checked(result);
      bindings(result);
    });
    test(
      'constructing another instance does not resolve an unknown this receiver',
      () async {
        skipped(
          await check(
            "class Builder { final String sql; Builder(this.sql); void example(dynamic session) { final other = Builder('select 1'); session.db.unsafeQuery(sql); } }",
          ),
        );
      },
    );
    test(
      'constructing another instance preserves a concrete receiver field',
      () async {
        checked(
          await check(
            "class Builder { final String sql; Builder(this.sql); String build() { final other = Builder('select 1'); return sql; } } void example(dynamic session) { session.db.unsafeQuery(Builder('select from;').build()); }",
          ),
          failures: 1,
        );
      },
    );
    test(
      'nested helpers preserve conditional mutations through the receiver',
      () async {
        skipped(
          await check(
            "class Builder { final Map<String, String> parameters; Builder(this.parameters); String inner(bool flag) { if (flag) parameters.clear(); return 'ignored'; } String middle(bool flag) => inner(flag); String outer(bool flag) { final ignored = middle(flag); return (this).parameters['sql']!; } } void example(dynamic session, bool flag) { session.db.unsafeQuery(Builder({'sql': 'select 1'}).outer(flag)); }",
          ),
        );
      },
    );
    for (final entry in <String, String>{
      'unknown instance receiver': "class Builder { String build() => 'select 1'; } void example(dynamic session, Builder builder) { session.db.unsafeQuery(builder.build()); }",
      'mutable field': "class Statement { String text; Statement(this.text); } void example(dynamic session) { final statement = Statement('select 1'); session.db.unsafeQuery(statement.text); }",
      'late final field': "class Statement { late final String text; Statement(String sql) { text = sql; } } void example(dynamic session) { session.db.unsafeQuery(Statement('select 1').text); }",
      'factory constructor': "class Statement { final String text; Statement._(this.text); factory Statement(String sql) => loadStatement(); } void example(dynamic session) { session.db.unsafeQuery(Statement('select 1').text); }",
      'constructor body': "class Statement { final String text; Statement(this.text) { notify(); } } void example(dynamic session) { session.db.unsafeQuery(Statement('select 1').text); }",
      'unknown record source': "void example(dynamic session, ({String text, Map<String, Object?> parameters}) statement) { session.db.unsafeQuery(statement.text); }",
      'runtime constructor field': "class Statement { final String text; Statement(this.text); } void example(dynamic session, String runtimeSql) { session.db.unsafeQuery(Statement(runtimeSql).text); }",
    }.entries) {
      test('${entry.key} remains unknown', () async {
        skipped(await check(entry.value));
      });
    }
  });

  group('static list and buffer assembly', () {
    final lists = <String, String>{
      'literal join': "final clauses = ['select', '1'];",
      'const list alias':
          "const parts = ['select', '1']; final clauses = [...parts];",
      'add': "final clauses = <String>[]; clauses.add('select'); clauses.add('1');",
      'addAll': "final clauses = <String>[]; clauses.addAll(['select', '1']);",
      'spread': "const first = ['select']; final clauses = [...first, '1'];",
      'clear': "final clauses = ['invalid']; clauses.clear(); clauses.addAll(['select', '1']);",
      'removeAt':
          "final clauses = ['select', 'invalid', '1']; clauses.removeAt(1);",
      'literal for-in': "final clauses = <String>[]; for (final part in ['select', '1']) { clauses.add(part); }",
      'const for-in': "const parts = ['select', '1']; final clauses = <String>[]; for (final part in parts) clauses.add(part);",
      'collection for': "const parts = ['select', '1']; final clauses = [for (final part in parts) part];",
      'collection if known':
          "final clauses = ['select', if (true) '1' else runtimeSql];",
      'fixed numeric loop': "final clauses = ['select']; for (var i = 0; i < 1; i++) { clauses.add('1'); }",
    };
    for (final entry in lists.entries) {
      test(entry.key, () async {
        checked(
          await check(
            "void example(dynamic session, String runtimeSql) { ${entry.value} session.db.unsafeQuery(clauses.join(' ')); }",
          ),
        );
      });
    }
    test('conditional list elements check each variant', () async {
      checked(
        await check(
          "void example(dynamic session, bool flag) { final clauses = ['select', if (flag) '1' else '2']; session.db.unsafeQuery(clauses.join(' ')); }",
        ),
        count: 2,
      );
    });
    test('conditional add invalid branch is checked', () async {
      checked(
        await check(
          "void example(dynamic session, bool flag) { final clauses = ['select']; if (flag) clauses.add('1'); else clauses.add('from;'); session.db.unsafeQuery(clauses.join(' ')); }",
        ),
        count: 2,
        failures: 1,
      );
    });
    test('list spread snapshot survives source mutation', () async {
      checked(
        await check(
          "void example(dynamic session) { final base = ['select', '1']; final clauses = [...base]; base.clear(); session.db.unsafeQuery(clauses.join(' ')); }",
        ),
      );
    });
    test('list alias writes preserve shared identity', () async {
      checked(
        await check(
          "void example(dynamic session) { final clauses = ['select']; final alias = clauses; alias.add('1'); session.db.unsafeQuery(clauses.join(' ')); }",
        ),
      );
    });
    test('later list writes do not alter an earlier call', () async {
      checked(
        await check(
          "void example(dynamic session, String runtimeSql) { final clauses = ['select', '1']; session.db.unsafeQuery(clauses.join(' ')); clauses.add(runtimeSql); }",
        ),
      );
    });
    test('constant enum values use each readable name', () async {
      checked(
        await check(
          r"enum Table { equipment, locations } void example(dynamic session) { final clauses = <String>[]; for (final table in Table.values) { clauses.add('select * from ${table.name}'); } session.db.unsafeQuery(clauses.join('; ')); }",
        ),
      );
    });
    test('bounded numeric loop expands each readable index', () async {
      checked(
        await check(
          r"void example(dynamic session) { final clauses = <String>[]; for (var i = 0; i < 3; i++) { clauses.add('select $i'); } session.db.unsafeQuery(clauses.join('; ')); }",
        ),
      );
    });
    test('query calls inside a finite loop cover every iteration', () async {
      checked(
        await check(
          r"void example(dynamic session) { for (final table in ['equipment', 'locations']) { session.db.unsafeQuery('select * from $table'); } }",
        ),
        count: 2,
      );
    });
    test('invalid query in a later finite iteration is checked', () async {
      checked(
        await check(
          "void example(dynamic session) { for (final sql in ['select 1', 'select from;']) session.db.unsafeQuery(sql); }",
        ),
        count: 2,
        failures: 1,
      );
    });
    test('constant enum fields preserve source strings', () async {
      checked(
        await check(
          "enum Table { equipment('select 1'), locations('select 2'); final String sql; const Table(this.sql); } void example(dynamic session) { final clauses = <String>[]; for (final table in Table.values) clauses.add(table.sql); session.db.unsafeQuery(clauses.join('; ')); }",
        ),
      );
    });
    test('finite loop builds placeholder names and binding keys', () async {
      final result = await check(
        r"void example(dynamic session) { final clauses = <String>[]; final params = <String, Object?>{}; for (final key in ['first', 'second']) { clauses.add('@$key'); params[key] = loadValue(); } session.db.unsafeQuery('select ${clauses.join(', ')}', parameters: QueryParameters.named(params)); }",
      );
      checked(result);
      bindings(result);
    });
    final buffers = <String, String>{
      'write':
          "final sql = StringBuffer(); sql.write('select'); sql.write(' 1');",
      'initial content': "final sql = StringBuffer('select'); sql.write(' 1');",
      'writeln': "final sql = StringBuffer(); sql.writeln('select'); sql.writeln('1');",
      'writeAll':
          "final sql = StringBuffer(); sql.writeAll(['select', '1'], ' ');",
      'clear': "final sql = StringBuffer('invalid'); sql.clear(); sql.write('select 1');",
      'cascade': "final sql = StringBuffer()..write('select')..write(' 1');",
      'finite loop': "final sql = StringBuffer(); for (final part in ['select', ' 1']) sql.write(part);",
    };
    for (final entry in buffers.entries) {
      test('StringBuffer ${entry.key}', () async {
        checked(
          await check(
            "void example(dynamic session) { ${entry.value} session.db.unsafeQuery(sql.toString()); }",
          ),
        );
      });
    }
    test('StringBuffer conditional write checks all branches', () async {
      checked(
        await check(
          "void example(dynamic session, bool flag) { final sql = StringBuffer('select '); if (flag) sql.write('1'); else sql.write('from;'); session.db.unsafeQuery(sql.toString()); }",
        ),
        count: 2,
        failures: 1,
      );
    });
    test('StringBuffer alias writes preserve shared identity', () async {
      checked(
        await check(
          "void example(dynamic session) { final sql = StringBuffer('select '); final alias = sql; alias.write('1'); session.db.unsafeQuery(sql.toString()); }",
        ),
      );
    });
    test('later StringBuffer writes do not alter an earlier call', () async {
      checked(
        await check(
          "void example(dynamic session, String runtimeSql) { final sql = StringBuffer('select 1'); session.db.unsafeQuery(sql.toString()); sql.write(runtimeSql); }",
        ),
      );
    });
    test('a user class named StringBuffer is not the builtin', () async {
      skipped(
        await check(
          "class StringBuffer { final String initial; StringBuffer(this.initial); String toString() => runtimeSql; } void example(dynamic session) { final sql = StringBuffer('select 1'); session.db.unsafeQuery(sql.toString()); }",
        ),
      );
    });
    test('a local function named StringBuffer is not the builtin', () async {
      skipped(
        await check(
          "void example(dynamic session) { dynamic StringBuffer(String initial) => loadBuilder(); final sql = StringBuffer('select 1'); session.db.unsafeQuery(sql.toString()); }",
        ),
      );
    });
    for (final entry in <String, String>{
      'runtime list loop': "final clauses = <String>[]; for (final part in parts) clauses.add(part); session.db.unsafeQuery(clauses.join(' '));",
      'runtime spread': "final clauses = ['select', ...parts]; session.db.unsafeQuery(clauses.join(' '));",
      'runtime join separator': "final clauses = ['select', '1']; session.db.unsafeQuery(clauses.join(runtimeSql));",
      'list runtime alias mutation': "final clauses = ['select', '1']; final alias = clauses; alias.add(runtimeSql); session.db.unsafeQuery(clauses.join(' '));",
      'list escape': "final clauses = ['select', '1']; mutate(clauses); session.db.unsafeQuery(clauses.join(' '));",
      'list closure mutation': "final clauses = ['select', '1']; void change() { clauses.clear(); } change(); session.db.unsafeQuery(clauses.join(' '));",
      'runtime buffer write': "final sql = StringBuffer('select '); sql.write(runtimeSql); session.db.unsafeQuery(sql.toString());",
      'buffer runtime alias mutation': "final sql = StringBuffer('select 1'); final alias = sql; alias.write(runtimeSql); session.db.unsafeQuery(sql.toString());",
      'buffer escape': "final sql = StringBuffer('select 1'); mutate(sql); session.db.unsafeQuery(sql.toString());",
      'unbounded while loop': "final sql = StringBuffer('select 1'); while (flag) sql.write(runtimeSql); session.db.unsafeQuery(sql.toString());",
      'escaped list index': "final clauses = ['select 1']; mutate(clauses); session.db.unsafeQuery(clauses[0]);",
      'escaped map index': "final queries = {'query': 'select 1'}; mutate(queries); session.db.unsafeQuery(queries['query']!);",
      'escaped list length guard': "final clauses = ['select 1']; mutate(clauses); final sql = clauses.length == 1 ? 'select 1' : runtimeSql; session.db.unsafeQuery(sql);",
      'escaped list emptiness guard': "final clauses = ['select 1']; mutate(clauses); final sql = clauses.isEmpty ? runtimeSql : 'select 1'; session.db.unsafeQuery(sql);",
      'escaped map length guard': "final params = {'id': 1}; mutate(params); final sql = params.length == 1 ? 'select 1' : runtimeSql; session.db.unsafeQuery(sql);",
      'escaped map emptiness guard': "final params = {'id': 1}; mutate(params); final sql = params.isEmpty ? runtimeSql : 'select 1'; session.db.unsafeQuery(sql);",
    }.entries) {
      test('${entry.key} remains unknown', () async {
        skipped(
          await check(
            "void example(dynamic session, List<String> parts, String runtimeSql, bool flag) { ${entry.value} }",
          ),
        );
      });
    }
  });

  group('helper statement assembly', () {
    final helpers = <String, (String, int, int)>{
      'local assignment': (
        "String build() { var sql = 'invalid'; sql = 'select 1'; return sql; }",
        1,
        0,
      ),
      'conditional append': (
        "String build(bool flag) { var sql = 'select 1'; if (flag) sql += ' where true'; return sql; }",
        2,
        0,
      ),
      'switch assignments': (
        "String build(int choice) { var sql = 'invalid'; switch (choice) { case 0: sql = 'select 1'; break; default: sql = 'select 2'; } return sql; }",
        2,
        0,
      ),
      'switch returns': (
        "String build(int choice) { switch (choice) { case 0: return 'select 1'; default: return 'select from;'; } }",
        2,
        1,
      ),
      'loop list helper': (
        "String build() { final clauses = <String>[]; for (final part in ['select', '1']) clauses.add(part); return clauses.join(' '); }",
        1,
        0,
      ),
      'StringBuffer helper': (
        "String build() { final sql = StringBuffer(); sql.write('select'); sql.writeln(' 1'); return sql.toString(); }",
        1,
        0,
      ),
    };
    for (final entry in helpers.entries) {
      test(entry.key, () async {
        final argument = entry.key == 'conditional append'
            ? 'flag'
            : entry.key.startsWith('switch')
            ? 'choice'
            : '';
        checked(
          await check(
            '${entry.value.$1} void example(dynamic session, bool flag, int choice) { session.db.unsafeQuery(build($argument)); }',
          ),
          count: entry.value.$2,
          failures: entry.value.$3,
        );
      });
    }
    test('a helper branch returning runtime SQL skips all results', () async {
      skipped(
        await check(
          "String build(bool flag, String runtimeSql) { var sql = 'select 1'; if (flag) sql = runtimeSql; return sql; } void example(dynamic session, bool flag, String runtimeSql) { session.db.unsafeQuery(build(flag, runtimeSql)); }",
        ),
      );
    });
    test('switch without a returning default remains unknown', () async {
      skipped(
        await check(
          "String build(int choice) { switch (choice) { case 0: return 'select 1'; } return runtimeSql; } void example(dynamic session, int choice) { session.db.unsafeQuery(build(choice)); }",
        ),
      );
    });
  });

  group('correlated SQL and binding conditions', () {
    for (final entry in <String, String>{
      'same conditional block':
          "if (flag) { sql += ' where id = @id'; params['id'] = 1; }",
      'separate same condition':
          "if (flag) sql += ' where id = @id'; if (flag) params['id'] = 1;",
      'negated condition':
          "if (!flag) sql += ' where id = @id'; if (!flag) params['id'] = 1;",
      'else matches negation': "if (flag) {} else sql += ' where id = @id'; if (!flag) params['id'] = 1;",
    }.entries) {
      test(entry.key, () async {
        final result = await check(
          "void example(dynamic session, bool flag) { var sql = 'select 1'; final params = <String, Object?>{}; ${entry.value} session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
        );
        checked(result, count: 2);
        bindings(result);
      });
    }
    test('conditional map literal correlates with SQL branch', () async {
      final result = await check(
        "void example(dynamic session, bool flag) { final sql = flag ? 'select @id' : 'select 1'; final params = {if (flag) 'id': 1}; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
      );
      checked(result, count: 2);
      bindings(result);
    });
    test('opposite conditions identify genuinely missing bindings', () async {
      final result = await check(
        "void example(dynamic session, bool flag) { var sql = 'select 1'; final params = <String, Object?>{}; if (flag) sql += ' where id = @id'; if (!flag) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
      );
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
    test('rebound condition is not assumed unchanged', () async {
      final result = await check(
        "void example(dynamic session, bool flag, bool other) { var condition = flag; var sql = 'select 1'; final params = <String, Object?>{}; if (condition) sql += ' where id = @id'; condition = other; if (condition) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
      );
      checked(result, count: 2);
      bindings(result, count: 0, skipped: 1);
    });
    test(
      'side effecting calls are not treated as the same condition',
      () async {
        final result = await check(
          "void example(dynamic session) { var sql = 'select 1'; final params = <String, Object?>{}; if (choose()) sql += ' where id = @id'; if (choose()) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
        );
        checked(result, count: 2);
        bindings(result, count: 0, skipped: 1);
      },
    );
  });

  group('runtime binding condition safeguards', () {
    test(
      'runtime property reads are not treated as the same condition',
      () async {
        final result = await check(
          "void example(dynamic session, dynamic filters) { var sql = 'select 1'; final params = <String, Object?>{}; if (filters.active) sql += ' where id = @id'; if (filters.active) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
        );
        checked(result, count: 2);
        bindings(result, count: 0, skipped: 1);
      },
    );
  });

  group('operator and captured condition safeguards', () {
    for (final operator in ['==', '<']) {
      test('repeated dynamic $operator can invoke different operators', () async {
        final result = await check(
          "void example(dynamic session, dynamic left, dynamic right) { var sql = 'select 1'; final params = <String, Object?>{}; if (left $operator right) sql += ' where id = @id'; if (left $operator right) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
        );
        checked(result, count: 2);
        bindings(result, count: 0, skipped: 1);
      });
    }
    test(
      'floating comparison complements do not assume NaN is absent',
      () async {
        final result = await check(
          "void example(dynamic session, double left, double right) { var sql = 'select 1'; final params = <String, Object?>{}; if (!(left < right)) sql += ' where id = @id'; if (left >= right) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
        );
        checked(result, count: 2);
        bindings(result, count: 0, skipped: 1);
      },
    );
    test(
      'object self equality does not ignore an overridden operator',
      () async {
        skipped(
          await check(
            "class Choice { bool operator ==(Object other) => false; } void example(dynamic session, String runtimeSql) { final choice = Choice(); final sql = choice == choice ? 'select 1' : runtimeSql; session.db.unsafeQuery(sql); }",
          ),
        );
      },
    );
    test(
      'separately captured runtime getter values remain independent',
      () async {
        final result = await check(
          "void example(dynamic session, dynamic filters) { final a = filters.flag; final b = filters.flag; var sql = 'select 1'; final params = <String, Object?>{}; if (a) sql += ' where id = @id'; if (b) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
        );
        checked(result, count: 2);
        bindings(result, count: 0, skipped: 1);
      },
    );
    test('one captured runtime getter value can be reused safely', () async {
      final result = await check(
        "void example(dynamic session, dynamic filters) { final active = filters.flag; var sql = 'select 1'; final params = <String, Object?>{}; if (active) sql += ' where id = @id'; if (active) params['id'] = 1; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
      );
      checked(result, count: 2);
      bindings(result);
    });
  });

  group('static class assembly helpers', () {
    test('static helper assembles a list before returning', () async {
      checked(
        await check(
          "class Queries { static String build() { final clauses = <String>[]; clauses.add('select'); clauses.add('1'); return clauses.join(' '); } } void example(dynamic session) { session.db.unsafeQuery(Queries.build()); }",
        ),
      );
    });
    test('static helper assembles a buffer before returning', () async {
      checked(
        await check(
          "class Queries { static String build() { final sql = StringBuffer(); sql.write('select'); sql.write(' 1'); return sql.toString(); } } void example(dynamic session) { session.db.unsafeQuery(Queries.build()); }",
        ),
      );
    });
  });

  group('assembled SQL origins and procedural bodies', () {
    test('Unicode joined fragment reports its original line', () async {
      final result = await check(
        "void example(dynamic session) {\n  final clauses = [\n    'select é,',\n    'from;',\n  ];\n  session.db.unsafeQuery(clauses.join(' '));\n}",
      );
      checked(result, failures: 1);
      expect(result.stderr, contains('FAIL endpoint.dart:4:'));
    });
    test('imported constructor field reports defining source', () async {
      File(p.join(fixture().path, 'queries.dart')).writeAsStringSync(
        "class Statement {\n  final String text;\n  const Statement(this.text);\n}\nconst statement = Statement('select é, from;');\n",
      );
      final result = await check(
        "import 'queries.dart'; void example(dynamic session) { session.db.unsafeQuery(statement.text); }",
      );
      checked(result, failures: 1);
      expect(result.stderr, contains('FAIL queries.dart:5:'));
    });
    for (final major in [17, 18]) {
      test(
        'uppercase PL fragments added through list aliases are not standalone SQL on $major',
        () async {
          final result = await check(
            r'''void example(dynamic session) { final clauses = <String>[]; final alias = clauses; alias.add(r'DO $body$'); alias.add('BEGIN NULL; END;'); alias.add(r'$body$;'); session.db.unsafeExecute(clauses.join(' ')); }''',
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
        'uppercase PL fragments written through buffer aliases are not standalone SQL on $major',
        () async {
          final result = await check(
            r'''void example(dynamic session) { final sql = StringBuffer(); final alias = sql; alias.write(r'DO $body$ '); alias.write('BEGIN NULL; END; '); alias.write(r'$body$;'); session.db.unsafeExecute(sql.toString()); }''',
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
        'uppercase PL fragments in buffer cascades are not standalone SQL on $major',
        () async {
          final result = await check(
            r'''void example(dynamic session) { final sql = StringBuffer()..write(r'DO $body$ ')..write('BEGIN NULL; END; ')..write(r'$body$;'); session.db.unsafeExecute(sql.toString()); }''',
            major: major,
          );
          checked(result);
          expect(
            result.stdout,
            contains('Checked 1 PL/pgSQL definitions; 0 failed.'),
          );
        },
      );
      test('list assembly PL/pgSQL succeeds on $major', () async {
        final result = await check(
          r'''void example(dynamic session) { final clauses = [r'do $body$', r"BEGIN RAISE NOTICE 'équipement'; END;", r'$body$;']; session.db.unsafeExecute(clauses.join(' ')); }''',
          major: major,
        );
        checked(result);
        expect(
          result.stdout,
          contains('Checked 1 PL/pgSQL definitions; 0 failed.'),
        );
      });
      test('StringBuffer PL/pgSQL failures retain source on $major', () async {
        final result = await check(r'''void example(dynamic session) {
  final sql = StringBuffer();
  sql.write(r'do $body$ BEGIN IF THEN END IF; END; $body$;');
  session.db.unsafeExecute(sql.toString());
}''', major: major);
        checked(result, failures: 1);
        expect(result.stderr, contains('FAIL endpoint.dart:3:'));
        expect(result.stderr, contains('PL/pgSQL:'));
      });
    }
  });
}
