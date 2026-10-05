import 'dart:convert';

import 'package:postgresql_parser/postgresql_parser.dart';
import 'package:test/test.dart';

void main() {
  for (final version in PostgresParser.supportedVersions) {
    group('$version', () {
      final parser = PostgresParser(version: version);

      test(
        'parses valid SQL into a decoded tree and preserves the raw JSON',
        () {
          final result = parser.parse('SELECT 1');

          expect(result.version, version);
          expect((result.tree['version'] as int) ~/ 10000, version.major);
          expect(result.tree['stmts'], hasLength(1));
          expect(jsonDecode(result.rawJson), result.tree);
        },
      );

      test('parses multiple statements', () {
        final result = parser.parse('SELECT 1; SELECT 2;');
        expect(result.tree['stmts'], hasLength(2));
      });

      test('reports syntax errors with a cursor position', () {
        expect(
          () => parser.parse('SELECT FROM'),
          throwsA(
            isA<PostgresParseException>()
                .having((error) => error.version, 'version', version)
                .having((error) => error.message, 'message', isNotEmpty)
                .having(
                  (error) => error.cursorPosition,
                  'cursor position',
                  greaterThan(0),
                ),
          ),
        );
      });

      test('accepts Unicode SQL text', () {
        final result = parser.parse("SELECT 'café' AS label");
        expect(result.tree['stmts'], hasLength(1));
      });

      test('rejects embedded NUL before calling native code', () {
        expect(() => parser.parse('SELECT 1\u0000'), throwsArgumentError);
      });

      test('can alternate successful and failing calls repeatedly', () {
        for (var i = 0; i < 100; i++) {
          expect(parser.parse('SELECT 1').tree['stmts'], hasLength(1));
          expect(
            () => parser.parse('SELECT FROM'),
            throwsA(isA<PostgresParseException>()),
          );
        }
      });
    });
  }

  test('PostgreSQL 17 rejects PostgreSQL 18 RETURNING WITH syntax', () {
    final parser = PostgresParser(version: PostgresVersion.v17);
    expect(
      () => parser.parse('UPDATE t SET x = 1 RETURNING WITH (OLD AS o) o.x'),
      throwsA(isA<PostgresParseException>()),
    );
  });

  test('PostgreSQL 16 rejects MERGE NOT MATCHED BY SOURCE added in 17', () {
    const sql =
        'MERGE INTO target t USING source s ON t.id = s.id '
        'WHEN NOT MATCHED BY SOURCE THEN DELETE';
    expect(
      () => PostgresParser(version: PostgresVersion.v16).parse(sql),
      throwsA(isA<PostgresParseException>()),
    );
    expect(
      PostgresParser(version: PostgresVersion.v17).parse(sql).tree['stmts'],
      hasLength(1),
    );
  });

  test('PostgreSQL 18 accepts RETURNING WITH syntax', () {
    final parser = PostgresParser(version: PostgresVersion.v18);
    final result = parser.parse(
      'UPDATE t SET x = 1 RETURNING WITH (OLD AS o) o.x',
    );
    expect(result.tree['stmts'], hasLength(1));
  });
}
