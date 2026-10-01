import 'dart:convert';

import 'package:postgresql_parser/postgresql_parser.dart';
import 'package:test/test.dart';

const _function = r'''
CREATE FUNCTION increment_positive(value integer) RETURNS integer AS $$
BEGIN
  IF value > 0 THEN
    RETURN value + 1;
  ELSE
    RETURN 0;
  END IF;
END;
$$ LANGUAGE plpgsql;
''';

const _invalidBody = r'DO $$ BEGIN IF THEN END IF; END; $$;';

void main() {
  for (final version in PostgresParser.supportedVersions) {
    group('PL/pgSQL $version', () {
      final parser = PostgresParser(version: version);

      test('parses parameters and procedural control flow into JSON', () {
        final result = parser.parsePlpgsql(_function);
        expect(result.version, version);
        expect(result.tree, hasLength(1));
        expect(result.tree.single, contains('PLpgSQL_function'));
        expect(result.rawJson, contains('PLpgSQL_stmt_if'));
        expect(result.rawJson, contains('value'));
        expect(jsonDecode(result.rawJson), result.tree);
      });

      test('parses trigger functions with NEW and OLD', () {
        final result = parser.parsePlpgsql(r'''
CREATE FUNCTION before_change() RETURNS trigger AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Cannot change id';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
''');
        expect(result.tree, hasLength(1));
        expect(result.rawJson, contains('Cannot change id'));
      });

      test('parses a complete procedure definition', () {
        final result = parser.parsePlpgsql(r'''
CREATE PROCEDURE announce(value integer) LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'Value: %', value;
END;
$$;
''');
        expect(result.tree, hasLength(1));
        expect(result.rawJson, contains('Value: %'));
      });

      test('parses DO with Unicode and custom dollar quoting', () {
        final result = parser.parsePlpgsql(r'''
DO $body$ BEGIN RAISE NOTICE 'café; 雪'; END; $body$;
''');
        expect(result.tree, hasLength(1));
        expect(result.rawJson, contains('café; 雪'));
        expect(jsonDecode(result.rawJson), result.tree);
      });

      test('preserves definition order and skips ordinary SQL', () {
        final result = parser.parsePlpgsql(r'''
SELECT 1;
DO $$ BEGIN RAISE NOTICE 'first'; END; $$;
CREATE TABLE example (id integer);
DO $$ BEGIN RAISE NOTICE 'second'; END; $$;
''');
        expect(result.tree, hasLength(2));
        expect(jsonEncode(result.tree[0]), contains('first'));
        expect(jsonEncode(result.tree[1]), contains('second'));
      });

      test('returns an empty list when there are no definitions', () {
        for (final sql in ['', '-- comment', 'SELECT 1; SELECT 2;']) {
          final result = parser.parsePlpgsql(sql);
          expect(result.tree, isEmpty);
          expect(jsonDecode(result.rawJson), result.tree);
        }
      });

      for (final sql in ['SELECT FROM', _invalidBody]) {
        test('reports upstream errors for $sql', () {
          expect(
            () => parser.parsePlpgsql(sql),
            throwsA(
              isA<PostgresParseException>()
                  .having((error) => error.version, 'version', version)
                  .having((error) => error.message, 'message', isNotEmpty)
                  .having(
                    (error) => error.cursorPosition,
                    'upstream cursor position',
                    greaterThanOrEqualTo(0),
                  ),
            ),
          );
        });
      }

      test('does not wrap bare bodies', () {
        expect(
          () => parser.parsePlpgsql('BEGIN RETURN; END;'),
          throwsA(isA<PostgresParseException>()),
        );
      });

      test('rejects embedded NUL before calling native code', () {
        expect(
          () => parser.parsePlpgsql('$_function\u0000'),
          throwsArgumentError,
        );
      });

      test('alternates successful and failing SQL and PL/pgSQL calls', () {
        for (var i = 0; i < 100; i++) {
          expect(parser.parse('SELECT 1').tree['stmts'], hasLength(1));
          expect(parser.parsePlpgsql(_function).tree, hasLength(1));
          expect(
            () => parser.parse('SELECT FROM'),
            throwsA(isA<PostgresParseException>()),
          );
          expect(
            () => parser.parsePlpgsql(_invalidBody),
            throwsA(isA<PostgresParseException>()),
          );
        }
      });
    });
  }

  test('alternates native assets without mixing selected versions', () {
    for (var i = 0; i < 10; i++) {
      for (final version in PostgresParser.supportedVersions) {
        final parser = PostgresParser(version: version);
        expect(parser.parsePlpgsql(_function).version, version);
        expect(
          (parser.parse('SELECT 1').tree['version'] as int) ~/ 10000,
          version.major,
        );
      }
    }
  });
}
