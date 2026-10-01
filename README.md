# postgresql_parser

A Dart pub workspace for PostgreSQL SQL parsing. The `postgresql_parser`
package currently supports the PostgreSQL 17 and 18 grammars on macOS and Linux.
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

From `packages/postgresql_parser`, run the generator with a tagged
`libpg_query` release:

```sh
dart run tool/add_postgres_version.dart --available
dart run tool/add_postgres_version.dart --list-releases 18
dart run tool/add_postgres_version.dart --list-tags 18
dart run tool/add_postgres_version.dart 18 --latest
```

`--available` shows the newest published release for each PostgreSQL major
version and whether that major is installed. `--list-releases 18` shows the
published releases for PostgreSQL 18. `--list-tags 18` shows Git tags,
including tags without a GitHub release.
These listing commands need network access and do not change the repository.
To choose a specific release, use `18 --tag <18-release-tag>` instead of
`18 --latest`. The generator refuses a major version that is already installed;
the `18 --latest` example above was used to create the checked-in 18 backend.

To update an installed major to a newer `libpg_query` release, add `--update`:

```sh
dart run tool/add_postgres_version.dart 18 --update --latest
```

The update keeps that major's C wrapper, Dart backend, and public API. It
replaces only its vendored upstream source and source pin, then runs
`dart analyze` and `dart test`. If validation fails, it restores the previous
source and pin. It refuses to overwrite uncommitted changes to those files.
When the installed pin is already the requested tag, it makes no changes.
Review the diff and run the tests on both macOS and Linux before publishing.

The add command checks out the release tag, records its exact commit in
`native/pg18/UPSTREAM.md`, detects the upstream `protobuf-c` or `upb` runtime,
vendors the required source and licenses, and generates a version-prefixed C
wrapper, native binding, Dart backend, `PostgresVersion.v18` constant, and
registry entry. The build hook reads `native/versions.json` and builds each
major version as a separate native asset. Application builds use the checked-in
source and do not access the network.

For a repeatable source check, pass `--expected-commit <full-git-sha>`; the
generator stops if the release tag resolves elsewhere. Older `protobuf-c`
releases with missing generated files require `protoc` and `protoc-gen-c` on
`PATH`; `upb` releases use their checked-in generated files. You may supply
an existing source archive with `--archive <local-tar.gz>` and verify it using
`--expected-sha256 <digest>`. Run `--help` for the full command. The generator
checks the upstream parse API shape, but a release
can still require wrapper or build changes. Review the generated diff, add a
syntax test specific to the new version, then run `dart analyze` and `dart test`
on macOS and Linux. The shared tests automatically cover every registered
version. The public `parse()` signature stays the same.

The source pins and license details are in
[`native/pg17/UPSTREAM.md`](packages/postgresql_parser/native/pg17/UPSTREAM.md)
and [`native/pg18/UPSTREAM.md`](packages/postgresql_parser/native/pg18/UPSTREAM.md).
