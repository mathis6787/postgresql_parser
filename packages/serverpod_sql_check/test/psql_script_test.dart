import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_sql_check/src/psql_script.dart';
import 'package:test/test.dart';

void main() {
  group('psql lexical handling', () {
    test('only standalone gexec becomes a terminator, preserving offsets', () {
      const sql =
          "SELECT '😀';\r\nSELECT 'SELECT 1'\r\n\t\\gexec \r\nSELECT 2;";
      final prepared = preparePsqlScript(sql);
      expect(prepared.unsupported, isNull);
      expect(prepared.gexecOffsets, [sql.indexOf(r'\gexec')]);
      expect(prepared.sql.length, sql.length);
      expect(prepared.sql, sql.replaceFirst(r'\gexec', ';     '));
    });

    test(
      'quoted text, identifiers, comments and bodies retain backslashes',
      () {
        const sql = r'''
SELECT '\gexec', 'it''s \gexec', "\gexec", E'escaped\'\gexec';
SELECT $$
\gexec
$$, $tag$
\if true
$tag$;
-- \gexec
/* outer /* \gexec */ \gexec */
SELECT foo$tag$ FROM example;
''';
        final prepared = preparePsqlScript(sql);
        expect(prepared.sql, sql);
        expect(prepared.gexecOffsets, isEmpty);
        expect(prepared.unsupported, isNull);
      },
    );

    for (final command in [
      r'\set tenant 42',
      r'\if true',
      r'\i other.sql',
      r'\copy things FROM stdin',
      r'\gexec extra',
      r'\gexecx',
      r'SELECT 1 \gexec',
    ]) {
      test('$command remains unsupported', () {
        final prepared = preparePsqlScript('SELECT 1\n$command\n');
        expect(prepared.unsupported, contains('unsupported psql command'));
      });
    }

    test('multiple query buffers retain independent terminators', () {
      const sql = 'SELECT 1\n\\gexec\nSELECT 2\n\\gexec\n';
      final prepared = preparePsqlScript(sql);
      expect(prepared.gexecOffsets, hasLength(2));
      expect(prepared.sql, 'SELECT 1\n;     \nSELECT 2\n;     \n');
    });
  });

  group('psql CLI', () {
    late Directory bundle;
    late Directory fixture;
    late String executable;

    setUpAll(() async {
      bundle = Directory.systemTemp.createTempSync('psql_check_cli_');
      final build = await Process.run(Platform.resolvedExecutable, [
        'build',
        'cli',
        '--target=bin/serverpod_sql_check.dart',
        '--output=${bundle.path}',
      ]);
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
      executable = p.join(bundle.path, 'bundle', 'bin', 'serverpod_sql_check');
      fixture = Directory.systemTemp.createTempSync('psql_check_source_');
      for (final entry in _fixtures.entries) {
        File(p.join(fixture.path, entry.key)).writeAsStringSync(entry.value);
      }
    });

    tearDownAll(() {
      fixture.deleteSync(recursive: true);
      bundle.deleteSync(recursive: true);
    });

    Future<ProcessResult> run(int major, List<String> files) =>
        Process.run(executable, [
          '--root=${fixture.path}',
          '--postgres-version=$major',
          '--verbose',
          ...files,
        ], workingDirectory: fixture.path);

    for (final major in [16, 17, 18]) {
      group('PostgreSQL $major', () {
        late ProcessResult result;
        late String output;

        setUpAll(() async {
          result = await run(major, []);
          output = '${result.stdout}\n${result.stderr}';
        });

        test('checks both file and Dart psql templates', () {
          expect(output, contains('OK setup.sql:'), reason: output);
          expect(output, contains('OK cleanup.dart:'), reason: output);
          expect(
            output,
            contains('OK PSQL GENERATED SQL setup.sql:'),
            reason: output,
          );
          expect(
            output,
            contains('NOT COVERED PSQL cleanup.dart:'),
            reason: output,
          );
          expect(output, isNot(contains('NOT COVERED PSQL setup.sql:')));
          expect(output, contains('string_agg is not statically evaluated'));
        });

        test(
          'invalid generated SQL and PL/pgSQL point to their source expression',
          () {
            for (final entry in {
              'generated_invalid.sql': "'CREAT DATABASE demo'",
              'generated_format.sql': 'pg_catalog.format',
              'generated_invalid.dart': 'format',
              'generated_body.sql': r'$command$',
              'generated_meta.sql': r'$command$',
            }.entries) {
              final source = _fixtures[entry.key]!;
              final prefix = source.substring(0, source.indexOf(entry.value));
              final line = '\n'.allMatches(prefix).length + 1;
              final column =
                  prefix.substring(prefix.lastIndexOf('\n') + 1).runes.length +
                  1;
              expect(
                output,
                contains(
                  'FAIL ${entry.key}:$line:$column: PSQL GENERATED SQL:',
                ),
                reason: output,
              );
            }
            expect(
              output,
              contains('generated SQL expression starts here'),
              reason: output,
            );
            expect(
              output,
              contains('PSQL GENERATED SQL: PL/pgSQL:'),
              reason: output,
            );
            expect(
              output,
              contains('generated SQL line 1, column 1'),
              reason: output,
            );
          },
        );

        test(
          'only output consumed by gexec receives generated SQL validation',
          () {
            for (final file in ['literal_only.sql', 'last_buffer.sql']) {
              expect(output, contains('OK $file:'), reason: output);
              expect(output, isNot(contains('FAIL $file:')), reason: output);
            }
            expect(
              output,
              contains('OK PSQL GENERATED SQL last_buffer.sql:'),
              reason: output,
            );
          },
        );

        test(
          'known columns are checked even when another column is unknown',
          () {
            expect(output, contains('FAIL mixed_outputs.sql:'), reason: output);
            expect(
              output,
              contains('NOT COVERED PSQL mixed_outputs.sql:'),
              reason: output,
            );
            expect(
              output,
              contains('command_text depends on database rows'),
              reason: output,
            );
          },
        );

        test('invalid constant generation expressions fail explicitly', () {
          expect(output, contains('FAIL invalid_format.sql:'), reason: output);
          expect(
            output,
            contains('format() %I cannot quote a NULL identifier'),
            reason: output,
          );
        });

        test(
          'SQL errors before and after gexec keep their original locations',
          () {
            for (final file in [
              'bad_before.sql',
              'bad_after.sql',
              'mapped.dart',
            ]) {
              final source = _fixtures[file]!;
              final offset = file == 'bad_before.sql'
                  ? source.indexOf(r'\gexec')
                  : source.indexOf('+ ;') + 2;
              final prefix = source.substring(0, offset);
              final line = '\n'.allMatches(prefix).length + 1;
              final column =
                  prefix.substring(prefix.lastIndexOf('\n') + 1).runes.length +
                  1;
              expect(
                output,
                contains('FAIL $file:$line:$column:'),
                reason: output,
              );
            }
          },
        );

        test('still validates PL/pgSQL after gexec', () {
          expect(output, contains('FAIL body.sql:'), reason: output);
          expect(
            output,
            contains('PL/pgSQL: missing expression'),
            reason: output,
          );
        });

        test('driver calls reject backslash commands', () {
          for (final file in [
            'raw_query.dart',
            'raw_execute.dart',
            'raw_unsupported.dart',
          ]) {
            expect(output, contains('FAIL $file:'), reason: output);
            expect(output, isNot(contains('SKIP PSQL $file:')), reason: output);
            expect(
              output,
              isNot(contains('NOT COVERED PSQL $file:')),
              reason: output,
            );
          }
        });

        test(
          'unsupported scripts are visibly skipped without a syntax failure',
          () {
            expect(
              output,
              contains('SKIP PSQL unsupported.sql:'),
              reason: output,
            );
            expect(
              output,
              isNot(contains('FAIL unsupported.sql:')),
              reason: output,
            );
            expect(
              output,
              contains('1 scripts/templates skipped'),
              reason: output,
            );
          },
        );

        test('ordinary quoted backslashes do not activate psql processing', () {
          expect(output, contains('OK quoted.sql:'), reason: output);
          expect(
            output,
            isNot(contains('NOT COVERED PSQL quoted.sql:')),
            reason: output,
          );
        });

        test('real syntax failures preserve exit code 1', () {
          expect(result.exitCode, 1, reason: output);
        });

        test(
          'psql support alone succeeds with explicit coverage limits',
          () async {
            final result = await run(major, [
              'setup.sql',
              'cleanup.dart',
              'quoted.sql',
              'generated_valid_body.sql',
              'generated_null.sql',
            ]);
            final output = '${result.stdout}\n${result.stderr}';
            expect(result.exitCode, 0, reason: output);
            expect(output, contains('0 failed;'), reason: output);
            expect(
              output,
              contains(r'PSQL: 4 \gexec commands'),
              reason: output,
            );
            expect(
              output,
              contains(
                'Checked 5 generated SQL outputs; 0 failed; 1 not covered.',
              ),
              reason: output,
            );
          },
        );
      });
    }
  });
}

const _fixtures = <String, String>{
  'setup.sql': r'''
SELECT pg_advisory_lock(41176, hashtext('local_enterprise_database'));
SELECT format('CREATE DATABASE %I', 'equip_track_enterprise')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'equip_track_enterprise'
)
\gexec
SELECT pg_advisory_unlock(41176, hashtext('local_enterprise_database'));
''',
  'cleanup.dart': r"""
const emptyDatabaseSql = r'''
SELECT format('TRUNCATE TABLE %s RESTART IDENTITY CASCADE',
  string_agg(format('%I.%I', schemaname, tablename), ', '))
FROM pg_tables
WHERE schemaname = 'public' AND tablename <> 'serverpod_migrations'
HAVING count(*) > 0
\gexec
''';
""",
  'bad_before.sql': 'SELECT 1 +\n\\gexec\n',
  'bad_after.sql': "SELECT 'SELECT 1'\r\n\\gexec\r\nSELECT '😀', 2 + ;\r\n",
  'mapped.dart':
      r'''const sql = "SELECT 'SELECT 1'\n\\gexec\nSELECT '😀', 2 + ;";''',
  'body.sql': r'''
SELECT 'SELECT 1'
\gexec
DO $$ BEGIN IF THEN END IF; END; $$;
''',
  'raw_query.dart': r"""
void example(dynamic session) {
  session.db.unsafeQuery(r'''SELECT 'SELECT 1'
\gexec
''');
}
""",
  'raw_execute.dart': r"""
void example(dynamic session) {
  session.db.unsafeExecute(r'''SELECT 'SELECT 1'
\gexec
''');
}
""",
  'raw_unsupported.dart': r"""
void example(dynamic session) {
  session.db.unsafeQuery(r'''SELECT 1
\if true
''');
}
""",
  'unsupported.sql': r'''
SELECT 'SELECT 1'
\gexec
\if true
SELECT 2;
\endif
''',
  'quoted.sql': r'''
SELECT '\gexec', 'it''s \gexec', "\gexec", $$
\gexec
$$, $tag$
\if true
$tag$;
-- \gexec
/* outer /* \gexec */ \gexec */
DO $$ BEGIN RAISE NOTICE '\gexec'; END; $$;
''',
  'generated_invalid.sql': "SELECT 'CREAT DATABASE demo'\n\\gexec\n",
  'generated_format.sql': "SELECT '😀';\r\nSELECT pg_catalog.format('CREAT DATABASE %I', 'demo')\r\n\\gexec\r\n",
  'generated_invalid.dart': r'''const generatorSql = "SELECT '😀';\nSELECT format('CREAT DATABASE %I', 'demo')\n\\gexec";''',
  'generated_body.sql': r'''
SELECT $command$DO $$ BEGIN IF THEN END IF; END; $$;$command$
\gexec
''',
  'generated_meta.sql': r'''
SELECT $command$\gexec$command$
\gexec
''',
  'generated_valid_body.sql': r'''
SELECT $command$DO $$ BEGIN RAISE EXCEPTION 'checker executed generated SQL'; END; $$;$command$
\gexec
''',
  'generated_null.sql': r'''
SELECT NULL, format(NULL), format('SELECT %L', NULL)
\gexec
''',
  'literal_only.sql': "SELECT 'CREAT DATABASE demo';",
  'last_buffer.sql': r'''
SELECT 'CREAT DATABASE demo';
SELECT 'SELECT 1';
\gexec
''',
  'mixed_outputs.sql': r'''
SELECT 'SELECT 1', 'CREAT DATABASE demo', command_text FROM commands
\gexec
''',
  'invalid_format.sql': "SELECT format('%I', NULL)\n\\gexec",
};
