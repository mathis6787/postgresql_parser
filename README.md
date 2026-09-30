# postgresql_parser

A Dart pub workspace for PostgreSQL SQL parsing. The `postgresql_parser`
package currently supports the PostgreSQL 17 grammar on macOS and Linux.
It wraps a pinned `libpg_query` source release and builds the native library
from the vendored files, so application builds do not download C source.

## Use the parser

```dart
import 'package:postgresql_parser/postgresql_parser.dart';

void main() {
  final parser = PostgresParser(version: PostgresVersion.v17);
  try {
    final result = parser.parse('SELECT 1; SELECT 2;');
    print(result.tree['stmts']); // Decoded upstream JSON tree.
    print(result.rawJson);       // Exact upstream JSON string.
  } on PostgresParseException catch (error) {
    print('${error.message} at ${error.cursorPosition}');
  }
}
```

`PostgresParser.supportedVersions` lists the available major versions. The
version is required when constructing a parser so adding a new grammar does
not change existing calls. `parse()` accepts one or more SQL statements.
The tree is `libpg_query`'s raw output; its fields can change between
PostgreSQL versions. Syntax parsing does not check whether tables, columns,
or types exist in a database.

## Development

Use Dart 3.13.4 or newer and Clang. The native build hook
supports macOS and Linux. From the repository root:

```sh
dart pub get
dart analyze
cd packages/postgresql_parser
dart test
```

Run `dart test` from the parser package directory so Dart discovers its
native build hook. The `serverpod_sql_check` package is still a placeholder.

## Adding a PostgreSQL major version

Keep each grammar in its own native asset. To add version 18, pin and vendor
a `libpg_query` 18 release under `native/pg18/`, add a version-prefixed C
wrapper with the same response contract, and build it as a distinct code
asset in `hook/build.dart`. Add the Dart backend and a `PostgresVersion.v18`
constant, then run the shared parser tests plus version-specific syntax
tests on macOS and Linux. The public `parse()` signature stays the same.
Only the wrapper's exported symbols should be visible from each native
library, so multiple grammars can coexist in one process.

The PostgreSQL 17 source pin and license details are in
[`native/pg17/UPSTREAM.md`](packages/postgresql_parser/native/pg17/UPSTREAM.md).
