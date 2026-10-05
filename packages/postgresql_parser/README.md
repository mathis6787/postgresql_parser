# postgresql_parser

Parse PostgreSQL SQL and PL/pgSQL into JSON syntax trees from Dart, using the
PostgreSQL parser provided by
[libpg_query](https://github.com/pganalyze/libpg_query).

Choose the PostgreSQL major version explicitly. The package bundles pinned
native sources and compiles them through a Dart build hook, so parsing does not
require a running database and builds do not download C source.

## Requirements

- Dart 3.13.4 or newer, within the supported Dart 3 SDK range.
- macOS or Linux with a C compiler available to the native build hook.

On macOS, install the Xcode command line tools. On Debian/Ubuntu, install
`clang`. Application builds use the committed bindings; libclang and `ffigen`
are only needed when regenerating those bindings.

The supported PostgreSQL grammars are **16, 17 and 18**. Windows, Android, iOS,
and web are currently unsupported.

## Installation

```sh
dart pub add postgresql_parser
```

Run the [standalone example](example/main.dart) with
`dart run example/main.dart` from the package directory.

## Parse SQL

```dart
import 'package:postgresql_parser/postgresql_parser.dart';

void main() {
  final parser = PostgresParser(version: PostgresVersion.v18);

  try {
    final result = parser.parse('SELECT 1; SELECT 2;');
    print(result.tree['stmts']);
    print(result.rawJson);
  } on PostgresParseException catch (error) {
    print('${error.message} at position ${error.cursorPosition}');
  }
}
```

`parse()` accepts one or more SQL statements. `PostgresParser.supportedVersions`
lists the available grammars. Selecting a version is required, so adding a new
grammar does not change existing callers.

## Parse PL/pgSQL

Use `parsePlpgsql()` to inspect procedural bodies in complete
`CREATE FUNCTION`, `CREATE PROCEDURE`, or `DO` statements:

```dart
import 'package:postgresql_parser/postgresql_parser.dart';

void main() {
  final parser = PostgresParser(version: PostgresVersion.v18);
  final result = parser.parsePlpgsql(r'''
CREATE FUNCTION increment_positive(value integer) RETURNS integer AS $$
BEGIN
  IF value > 0 THEN
    RETURN value + 1;
  END IF;
  RETURN 0;
END;
$$ LANGUAGE plpgsql;
''');

  print(result.tree);
  print(result.rawJson);
}
```

The result contains definitions in script order. Ordinary SQL statements do
not produce PL/pgSQL entries; a script with no definitions returns an empty
list. Wrap a bare `BEGIN ... END` body in a complete definition or `DO`
statement before parsing it. Other procedural languages are not validated.

## Results and errors

| Method | Result type | Decoded `tree` |
| --- | --- | --- |
| `parse(sql)` | `ParseResult` | `Map<String, dynamic>` |
| `parsePlpgsql(sql)` | `PlpgsqlParseResult` | `List<Map<String, dynamic>>` |

Both result types expose `version` and the exact upstream JSON string as
`rawJson`. The decoded trees retain upstream field names and structure;
fields and supported constructs may differ between PostgreSQL versions.

Upstream parsing errors throw `PostgresParseException`, which includes the
selected version, message, and cursor position. Positions are preserved as
reported by PostgreSQL and are zero when unavailable. For PL/pgSQL, a position
may refer to the function body rather than the entire script. Embedded NUL
characters are rejected with `ArgumentError` before calling native code.

## Limitations

Parsing checks syntax without executing SQL. It does not verify that tables,
columns, or types exist, validate runtime behavior, or inspect SQL constructed
dynamically inside a procedural body. PL/pgSQL support follows the selected
upstream version and is not a full database-side function validator.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and maintenance.

The upstream source pins, local compatibility patches, and third-party license
notices are documented in [PostgreSQL 16 source details](native/pg16/UPSTREAM.md),
[PostgreSQL 17 source details](native/pg17/UPSTREAM.md), and
[PostgreSQL 18 source details](native/pg18/UPSTREAM.md).

## License

Original package code is licensed under [MIT](LICENSE). Vendored sources retain
their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
