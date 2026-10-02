import 'package:postgresql_parser/postgresql_parser.dart';
import 'package:serverpod_sql_check/src/database_check.dart';
import 'package:serverpod_sql_check/src/sql_parameters.dart';
import 'package:test/test.dart';

void main() {
  group('PostgreSQL parameters', () {
    test('repeated names preserve indexes and original offsets', () {
      const sql = 'SELECT @first::int + @first, @second::text';
      final result = normalizeSqlParameters(sql);
      expect(result.sql, r'SELECT $1::int + $1, $2::text');
      expect(result.namedOffsets, {'first': 7, 'second': 29});
      expect(
        result.offsets[result.sql.lastIndexOf(r'$1')],
        sql.lastIndexOf('@first'),
      );
      expect(result.mixesParameters, isFalse);
    });

    test('quotes, dollar bodies and nested comments are untouched', () {
      const sql = r'''SELECT 'it''s @ignored $1', "@identifier", $body$@ignored $1; $body$,
        @id::int /* @ignored $2 /* nested @ignored */ */ -- @ignored $3
      ''';
      final result = normalizeSqlParameters(sql);
      expect(result.sql, sql.replaceFirst('@id::int', r'$1::int'));
      expect(result.namedOffsets.keys, ['id']);
      expect(result.hasPositional, isFalse);
    });

    test('ordinary backslashes and E-string escapes use PostgreSQL rules', () {
      const sql = r"SELECT '\', @id::int, E'it\'s @ignored $2'";
      final result = normalizeSqlParameters(sql);
      expect(result.sql, sql.replaceFirst('@id', r'$1'));
      expect(result.hasPositional, isFalse);
    });

    test(
      'positional parameters survive and mixed conventions are detected',
      () {
        expect(
          normalizeSqlParameters(r'SELECT $1::int').sql,
          r'SELECT $1::int',
        );
        expect(
          normalizeSqlParameters(r'SELECT $1::int').mixesParameters,
          isFalse,
        );
        expect(
          normalizeSqlParameters(r'SELECT $1::int, @id').mixesParameters,
          isTrue,
        );
        expect(
          normalizeSqlParameters(r'SELECT field$1, @id').hasPositional,
          isFalse,
        );
      },
    );

    test('many parameters and Unicode retain complete source mapping', () {
      final sql =
          "SELECT '😀', ${List.generate(12, (i) => '@parameter_$i').join(', ')}";
      final result = normalizeSqlParameters(sql);
      expect(result.sql, contains(r'$12'));
      expect(result.offsets.length, result.sql.length);
      expect(
        result.offsets[result.sql.indexOf(r'$12')],
        sql.indexOf('@parameter_11'),
      );
      expect(result.offsets[result.sql.indexOf('😀')], sql.indexOf('😀'));
    });
  });

  for (final version in PostgresParser.supportedVersions) {
    final parser = PostgresParser(version: version);
    group('database statements PostgreSQL ${version.major}', () {
      List<DatabaseStatement> statements(String sql) =>
          databaseStatements(parser.parse(sql), sql);

      test('selects only PREPARE statement types', () {
        const sql = '''SELECT 1; VALUES (1); INSERT INTO p VALUES (1);
          UPDATE p SET id = 2; DELETE FROM p;
          MERGE INTO p USING q ON p.id = q.id WHEN MATCHED THEN DELETE;
          SELECT 1 INTO copy; CREATE TABLE other(id int);
          DO \$\$ BEGIN NULL; END; \$\$; CALL procedure(); COPY p TO STDOUT;''';
        final result = statements(sql);
        expect(
          result.take(6).every((s) => s.unsupportedReason == null),
          isTrue,
        );
        expect(
          result.skip(6).every((s) => s.unsupportedReason != null),
          isTrue,
        );
        expect(result[6].unsupportedReason, contains('SELECT INTO'));
      });

      test('splits using AST byte positions, including Unicode and comments', () {
        const sql =
            "/* 😀; */ SELECT 'café; 😀'; -- comment;\nSELECT \$tag\$;😀\$tag\$;";
        final result = statements(sql);
        expect(result, hasLength(2));
        // Upstream 17/18 differ in whether stmt_location includes comments.
        expect(result[0].sql, contains("SELECT 'café; 😀'"));
        expect(result[1].sql, contains("SELECT \$tag\$;😀\$tag\$"));
        for (final statement in result) {
          expect(statement.sql, sql.substring(statement.start, statement.end));
          expect(parser.parse(statement.sql).tree['stmts'], hasLength(1));
        }
      });

      test('empty scripts have no statements and writable CTEs stay intact', () {
        expect(statements('; -- empty\n;'), isEmpty);
        final result = statements(
          'WITH changed AS (DELETE FROM p RETURNING *) SELECT * FROM changed;',
        );
        expect(result, hasLength(1));
        expect(result.single.unsupportedReason, isNull);
      });
    });
  }
}
