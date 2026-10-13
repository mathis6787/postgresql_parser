import 'dart:io';

import 'package:postgresql_parser/postgresql_parser.dart';
import 'package:serverpod_sql_check/src/generated_sql.dart';
import 'package:serverpod_sql_check/src/psql_keywords.dart';
import 'package:serverpod_sql_check/src/psql_script.dart';
import 'package:test/test.dart';

void main() {
  for (final version in PostgresParser.supportedVersions) {
    group('generated SQL PostgreSQL ${version.major}', () {
      final parser = PostgresParser(version: version);

      List<GeneratedSql> outputs(String source) {
        final prepared = preparePsqlScript(source);
        expect(prepared.unsupported, isNull);
        return generatedPsqlSql(
          parser.parse(prepared.sql),
          prepared.sql,
          prepared.gexecOffsets,
        );
      }

      List<GeneratedSql> select(String expression) =>
          outputs('SELECT $expression\n\\gexec\n');

      String? value(String expression) {
        final output = select(expression).single;
        expect(output.reason, isNull);
        expect(output.error, isNull);
        return output.sql;
      }

      test(
        'literal and concatenated SQL can expose an invalid generated command',
        () {
          final generated = value("'CREAT ' || 'DATABASE demo'");
          expect(generated, 'CREAT DATABASE demo');
          expect(
            () => parser.parse(generated!),
            throwsA(isA<PostgresParseException>()),
          );
        },
      );

      test(
        'constant projection remains readable with a runtime WHERE or FROM',
        () {
          final output = outputs(r'''
SELECT format('CREATE DATABASE %I', 'equip_track_enterprise')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'equip_track_enterprise')
\gexec
''').single;
          expect(output.sql, 'CREATE DATABASE equip_track_enterprise');
          expect(output.reason, isNull);
          parser.parse(output.sql!);
          expect(
            outputs("SELECT 'SELECT 1' FROM runtime_rows\n\\gexec").single.sql,
            'SELECT 1',
          );
        },
      );

      test('known empty result sets do not produce invalid commands', () {
        for (final condition in ['WHERE false', 'WHERE NULL', 'LIMIT 0']) {
          final output = select("'CREAT DATABASE demo' $condition").single;
          expect(output.sql, isNull);
          expect(output.reason, isNull);
          expect(output.ignoredReason, contains('no result rows'));
        }
      });

      test(
        'every output column is considered and unknown values remain unknown',
        () {
          final output = select("'SELECT 1', command_text FROM commands");
          expect(output.first.sql, 'SELECT 1');
          expect(
            output.last.reason,
            contains('command_text depends on database rows'),
          );
        },
      );

      test(
        'each gexec uses its own buffer, or the last query for an empty buffer',
        () {
          final output = outputs(r'''
SELECT 'SELECT 1'
\gexec
SELECT 'SELECT 2';
\gexec
\gexec
''');
          expect(output.map((o) => o.sql), [
            'SELECT 1',
            'SELECT 2',
            'SELECT 2',
          ]);
        },
      );

      test(
        'identifier quoting preserves case, escaping and keyword categories',
        () {
          expect(value("format('%I', 'safe_name')"), 'safe_name');
          expect(value("format('%I', 'merge')"), 'merge');
          expect(value("format('%I', 'select')"), '"select"');
          expect(value("format('%I', 'Camel Case')"), '"Camel Case"');
          expect(value("format('%I', 'a\"b')"), '"a""b"');
          expect(value("format('%I', 'équipement')"), '"équipement"');
          expect(
            value("format('%I', 'json')"),
            version.major == 16 ? 'json' : '"json"',
          );
        },
      );

      test('identifier keyword snapshot matches the selected pinned grammar', () {
        final file = File(
          '../postgresql_parser/native/pg${version.major}/libpg_query/src/postgres/include/parser/kwlist.h',
        );
        final expected = RegExp(r'PG_KEYWORD\("([^"]+)", [^,]+, ([^,]+),')
            .allMatches(file.readAsStringSync())
            .where((m) => m.group(2) != 'UNRESERVED_KEYWORD')
            .map((m) => m.group(1)!);
        expect(psqlQuotedKeywords[version.major], unorderedEquals(expected));
      });

      test('literal quoting preserves quotes, backslashes and SQL NULL', () {
        expect(value("format('%L', 'it''s')"), "'it''s'");
        expect(value(r"format('%L', 'a\b')"), r"E'a\\b'");
        expect(value("format('%L', NULL)"), 'NULL');
        final generated = value(r"format('SELECT %L', 'a\b')")!;
        final constant =
            (((parser.parse(generated).tree['stmts'] as List).single
                        as Map)['stmt']
                    as Map)['SelectStmt']
                as Map;
        expect(
          (((constant['targetList'] as List).single as Map)['ResTarget']
              as Map)['val'],
          contains('A_Const'),
        );
      });

      test(
        'format supports positions, widths, Unicode and escaped percent',
        () {
          expect(value(r"format('%2$s %1$s %%', 'one', 'two')"), 'two one %');
          expect(value("format('|%4s|', '😀')"), '|   😀|');
          expect(value("format('|%-4s|', 'x')"), '|x   |');
          expect(value("format('|%*s|', -4, 'x')"), '|x   |');
          expect(value(r"format('|%*2$s|', 'foo', 4, 'bar')"), '| bar|');
          expect(value(r"format('|%1$*2$s|', 'foo', 4, 'bar')"), '| foo|');
          expect(value("pg_catalog.format('SELECT %s', '1')"), 'SELECT 1');
          expect(value("format('SELECT %s', '1', runtime_value)"), 'SELECT 1');
        },
      );

      test(
        'NULL result cells are ignored, and NULL formatting follows PostgreSQL',
        () {
          expect(value('NULL'), isNull);
          expect(value("format(NULL, 'unused')"), isNull);
          expect(value("'SELECT ' || NULL"), isNull);
          expect(value("format('SELECT %s', NULL)"), 'SELECT ');
          expect(
            select("format('%I', NULL)").single.error,
            contains('NULL identifier'),
          );
        },
      );

      test('only known text casts and representations are evaluated', () {
        expect(value("''"), '');
        expect(value("format('SELECT %s, %L', 0, false)"), "SELECT 0, 'f'");
        expect(value("'SELECT 1'::text"), 'SELECT 1');
        expect(value("format('SELECT %s, %L', 12, true)"), "SELECT 12, 't'");
        expect(select("'SELECT 12'::varchar(8)").single.reason, isNotNull);
        expect(select("format('SELECT %s', 1.25)").single.reason, isNotNull);
      });

      test('runtime generators and user functions are not executed or guessed', () {
        expect(
          select(
            "format('TRUNCATE %s', string_agg(tablename, ',')) FROM pg_tables",
          ).single.reason,
          contains('string_agg'),
        );
        expect(
          select("custom.format('SELECT %s', '1')").single.reason,
          contains('custom.format'),
        );
        expect(
          select("format('%s', expensive_function())").single.reason,
          contains('expensive_function'),
        );
        expect(
          select("CASE WHEN runtime_flag THEN 'SELECT 1' ELSE 'SELECT 2' END")
              .single
              .reason,
          isNotNull,
        );
      });

      test('invalid constant format specifications are diagnosed', () {
        for (final expression in [
          "format('%Z', 'x')",
          "format('%s')",
          r"format('%0$s', 'x')",
          r"format('%999999999999999999999999$s', 'x')",
          "format('%*s', 'bad', 'x')",
        ]) {
          expect(
            select(expression).single.error,
            isNotNull,
            reason: expression,
          );
        }
      });

      test(
        'generation limits leave the output uncovered instead of guessing',
        () {
          expect(
            select("format('%65537s', 'x')").single.reason,
            contains('text limit'),
          );
          expect(
            select(List.filled(33, "'SELECT 1'").join(', ')).single.reason,
            contains('32-column limit'),
          );
          var expression = "'SELECT 1'";
          for (var i = 0; i < 34; i++) {
            expression = "format('%s', $expression)";
          }
          expect(select(expression).single.reason, contains('depth limit'));
        },
      );

      test('byte positions become original UTF-16 expression offsets', () {
        const source =
            "SELECT '😀';\r\nSELECT format('CREAT DATABASE %I', 'demo')\r\n\\gexec";
        final output = outputs(source).single;
        expect(output.expressionOffset, source.indexOf('format'));
      });

      test('unsupported result shapes remain visibly unknown', () {
        for (final source in [
          "SELECT 'SELECT 1' UNION ALL SELECT 'SELECT 2'\n\\gexec",
          "VALUES ('SELECT 1')\n\\gexec",
          "DELETE FROM things RETURNING 'SELECT 1'\n\\gexec",
          r'\gexec',
        ]) {
          expect(outputs(source).single.reason, isNotNull);
        }
      });
    });
  }
}
