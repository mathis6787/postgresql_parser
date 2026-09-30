import 'dart:convert';

import 'package:postgresql_parser/postgresql_parser.dart';
import 'package:test/test.dart';

void main() {
  final parser = PostgresParser(version: PostgresVersion.v17);

  test('parses valid SQL into a decoded tree and preserves the raw JSON', () {
    final result = parser.parse('SELECT 1');

    expect(result.version, PostgresVersion.v17);
    expect((result.tree['version'] as int) ~/ 10000, 17);
    expect(result.tree['stmts'], hasLength(1));
    expect(jsonDecode(result.rawJson), result.tree);
  });

  test('parses multiple statements', () {
    final result = parser.parse('SELECT 1; SELECT 2;');
    expect(result.tree['stmts'], hasLength(2));
  });

  test('reports syntax errors with a cursor position', () {
    expect(
      () => parser.parse('SELECT FROM'),
      throwsA(
        isA<PostgresParseException>()
            .having((error) => error.version, 'version', PostgresVersion.v17)
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

  test('rejects PostgreSQL 18 RETURNING WITH syntax', () {
    expect(
      () => parser.parse('UPDATE t SET x = 1 RETURNING WITH (OLD AS o) o.x'),
      throwsA(isA<PostgresParseException>()),
    );
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
}
