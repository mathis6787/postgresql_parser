import 'dart:io';

import 'package:test/test.dart';

final class _Fixture {
  _Fixture(String source, {this.failures = 0, this.errorStarts = const []})
    : source = source.trimLeft();

  final String source;
  final int failures;
  final List<String> errorStarts;
}

final _fixtures = <String, _Fixture>{
  'function.sql': _Fixture(r'''
CREATE FUNCTION positive(value integer) RETURNS integer AS $body$
BEGIN
  IF value > 0 THEN RETURN value; END IF;
  RETURN 0;
END;
$body$ LANGUAGE plpgsql;
'''),
  'procedure.sql': _Fixture(r'''
CREATE PROCEDURE announce() LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'hello'; END;
$$;
'''),
  'trigger.sql': _Fixture(r'''
CREATE FUNCTION on_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Cannot change id';
  END IF;
  RETURN NEW;
END;
$$;
'''),
  'inline.sql': _Fixture(
    r"DO $$ BEGIN RAISE NOTICE '@not_a_binding'; END; $$;",
  ),
  'raw_execute.dart': _Fixture(r"""
void example(dynamic session) {
  session.db.unsafeExecute(r'''DO $body$ BEGIN NULL; END; $body$;''');
}
"""),
  'quoted_body.dart': _Fixture(r'''
void example(dynamic session) {
  session.db.unsafeExecute("DO 'BEGIN RAISE NOTICE ''café''; END;';");
}
'''),
  'invalid_do.sql': _Fixture(
    r'DO $$ BEGIN IF THEN END IF; END; $$;',
    failures: 1,
    errorStarts: ['DO'],
  ),
  'invalid_function.sql': _Fixture(
    r'''
CREATE FUNCTION broken(value integer) RETURNS integer LANGUAGE plpgsql AS $$
BEGIN IF value > 0 THEN RETURN 1; END; $$;
''',
    failures: 1,
    errorStarts: ['CREATE FUNCTION'],
  ),
  'invalid_procedure.sql': _Fixture(
    r'CREATE PROCEDURE broken() LANGUAGE plpgsql AS $$ BEGIN IF THEN END; $$;',
    failures: 1,
    errorStarts: ['CREATE PROCEDURE'],
  ),
  'mixed_languages.sql': _Fixture(
    r'''
SELECT 'café; 😀';
CREATE FUNCTION sql_only() RETURNS integer LANGUAGE sql AS $$ SELECT FROM $$;
DO LANGUAGE plpython3u $$ this is not PL/pgSQL $$;
DO $bad$ BEGIN IF THEN END IF; END; $bad$;
CREATE PROCEDURE fine() LANGUAGE plpgsql AS $$ BEGIN NULL; END; $$;
DO $$ BEGIN IF THEN END IF; END; $$;
''',
    failures: 2,
    errorStarts: [r'DO $bad$', r'DO $$'],
  ),
  'missing_bodies.sql': _Fixture(
    r'''
CREATE FUNCTION no_body() RETURNS void LANGUAGE plpgsql;
DO LANGUAGE plpgsql;
''',
    failures: 2,
    errorStarts: ['CREATE FUNCTION', 'DO'],
  ),
  'sql_body.sql': _Fixture(r'''
CREATE FUNCTION sql_body() RETURNS integer BEGIN ATOMIC SELECT 1; END;
'''),
  'quoted_keywords.sql': _Fixture(r'''
-- DO $$ BEGIN IF THEN END; $$;
SELECT 'CREATE FUNCTION fake() LANGUAGE plpgsql AS $$ bad $$';
'''),
  'source_mapping.dart': _Fixture(
    r'''
const sql = "SELECT '😀', @a_very_long_parameter;\nDO \$body\$ BEGIN IF THEN END IF; END; \$body\$;";
void example(dynamic session) {
  session.db.unsafeExecute(sql, parameters: QueryParameters.named({'a_very_long_parameter': 1}));
}
''',
    // Both the template and its use are checked, using the original initializer.
    failures: 2,
    errorStarts: ['DO'],
  ),
  'conditional.dart': _Fixture(
    r"""
void example(dynamic session, bool flag) {
  final sql = flag
      ? r'''DO $$ BEGIN NULL; END; $$;'''
      : r'''DO $$ BEGIN IF THEN END IF; END; $$;''';
  session.db.unsafeExecute(sql);
}
""",
    failures: 2,
    errorStarts: [r'DO $$ BEGIN IF'],
  ),
  'runtime.dart': _Fixture(r"""
void example(dynamic session, String body) {
  session.db.unsafeExecute('DO \$\$ $body \$\$;');
}
"""),
  'cte.dart': _Fixture(r"const cteSql = 'WITH example AS (SELECT 1)';"),
};

Future<ProcessResult> _run(
  Directory root,
  int major,
  List<String> paths, {
  bool migrations = false,
}) => Process.run(Platform.resolvedExecutable, [
  'run',
  'bin/serverpod_sql_check.dart',
  '--verbose',
  '--root=${root.path}',
  '--postgres-version=$major',
  if (migrations) '--include-migrations',
  ...paths,
], workingDirectory: Directory.current.path);

void main() {
  for (final major in [16, 17, 18]) {
    group('PL/pgSQL PostgreSQL $major', () {
      late Directory directory;
      late ProcessResult result;
      late String output;

      setUpAll(() async {
        directory = await Directory.systemTemp.createTemp('sql_plpgsql_');
        for (final entry in _fixtures.entries) {
          await File('${directory.path}/${entry.key}')
              .writeAsString(entry.value.source);
        }
        result = await _run(directory, major, []);
        output = '${result.stdout}\n${result.stderr}';
      });

      tearDownAll(() async => directory.delete(recursive: true));

      for (final entry in _fixtures.entries) {
        test(entry.key, () {
          final fixture = entry.value;
          final failures = output
              .split('\n')
              .map((line) {
                // Build-hook progress may precede the first stderr diagnostic.
                final start = line.indexOf('FAIL ');
                return start < 0 ? line : line.substring(start);
              })
              .where((line) => line.startsWith('FAIL ${entry.key}:'))
              .toList();
          expect(failures, hasLength(fixture.failures), reason: output);
          if (fixture.failures > 0) {
            expect(
              failures,
              everyElement(contains('PL/pgSQL:')),
              reason: output,
            );
            expect(
              failures,
              everyElement(contains('PL/pgSQL block starts here')),
              reason: output,
            );
            for (final start in fixture.errorStarts) {
              final offset = fixture.source.indexOf(start);
              final prefix = fixture.source.substring(0, offset);
              final line = '\n'.allMatches(prefix).length + 1;
              final column =
                  prefix.substring(prefix.lastIndexOf('\n') + 1).runes.length +
                  1;
              expect(
                failures,
                contains(contains('${entry.key}:$line:$column:')),
                reason: output,
              );
            }
          } else if (entry.key == 'runtime.dart') {
            expect(output, contains('SKIP runtime.dart:'), reason: output);
          } else {
            expect(output, contains('OK ${entry.key}:'), reason: output);
          }
        });
      }

      test('body failures fail the CLI and have a separate summary', () {
        expect(result.exitCode, 1, reason: output);
        expect(
          output,
          contains(RegExp(r'Checked \d+ PL/pgSQL definitions; 11 failed\.')),
          reason: output,
        );
        expect(output, contains('0 missing bindings;'), reason: output);
        expect(output, contains('(CTE fragment)'), reason: output);
        expect(output, contains('(variant 2)'), reason: output);
      });

      test(
        'valid PL/pgSQL and other languages complete successfully',
        () async {
          final paths = _fixtures.entries
              .where((entry) => entry.value.failures == 0)
              .map((entry) => '${directory.path}/${entry.key}')
              .toList();
          final passed = await _run(directory, major, paths);
          final text = '${passed.stdout}\n${passed.stderr}';
          expect(passed.exitCode, 0, reason: text);
          expect(
            text,
            contains('Checked 6 PL/pgSQL definitions; 0 failed.'),
            reason: text,
          );
        },
      );

      test('migration bodies require include-migrations', () async {
        final root = await Directory('${directory.path}/migration_project')
            .create();
        final migrations = await Directory('${root.path}/migrations').create();
        await File('${migrations.path}/migration.sql')
            .writeAsString(_fixtures['invalid_do.sql']!.source);
        final excluded = await _run(root, major, []);
        expect(
          excluded.exitCode,
          0,
          reason: '${excluded.stdout}\n${excluded.stderr}',
        );
        expect(
          excluded.stdout,
          contains('Checked 0 PL/pgSQL definitions; 0 failed.'),
        );
        final included = await _run(root, major, [], migrations: true);
        expect(
          included.exitCode,
          1,
          reason: '${included.stdout}\n${included.stderr}',
        );
        expect(
          included.stdout,
          contains('Checked 1 PL/pgSQL definitions; 1 failed.'),
        );
        expect(included.stderr, contains('FAIL migrations/migration.sql:1:1:'));
      });
    });
  }
}
