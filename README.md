# postgresql_parser

A Dart pub workspace containing packages for parsing and statically
checking PostgreSQL SQL.

## Packages

- [`packages/postgresql_parser`](packages/postgresql_parser) — A Dart
  parser for PostgreSQL SQL. It is being prepared to wrap the
  [`libpg_query`](https://github.com/pganalyze/libpg_query) C library via
  `dart:ffi`, `ffigen` and Dart native build hooks. The native bindings
  and build hook are not implemented yet — only the dependencies are in
  place.
- [`packages/serverpod_sql_check`](packages/serverpod_sql_check) — Static
  SQL checking utilities for Serverpod, built on top of
  `postgresql_parser`. Currently an empty placeholder package with no
  dependencies or implementation.

Implementation for both packages will follow in later commits.

## Development

This repository uses a
[Dart pub workspace](https://dart.dev/tools/pub/workspaces). From the
repository root:

```sh
dart pub get
dart analyze
```
