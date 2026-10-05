import 'package:postgresql_parser/postgresql_parser.dart';

void main() {
  for (final version in PostgresParser.supportedVersions) {
    final parser = PostgresParser(version: version);
    final sql = parser.parse('SELECT 1; SELECT 2;');
    final plpgsql = parser.parsePlpgsql(r'''
DO $body$
BEGIN
  IF 1 < 2 THEN
    RAISE NOTICE 'parsed, never executed';
  END IF;
END;
$body$;
''');
    print(
      'PostgreSQL ${version.major}: '
      '${(sql.tree['stmts'] as List).length} SQL statements, '
      '${plpgsql.tree.length} PL/pgSQL definition.',
    );
  }
}
