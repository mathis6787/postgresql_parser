# Contributing to serverpod_sql_check

Clone [the repository](https://github.com/mathis6787/postgresql_parser) and use its
Dart pub workspace. Requires Dart 3.13.4+, macOS/Linux and a C compiler. Binding
generation additionally requires libclang; it is not part of normal CLI builds.

From the repository root:

```sh
dart pub get
dart analyze
cd packages/serverpod_sql_check
dart test --concurrency=1 --timeout=3m
dart build cli --target=bin/serverpod_sql_check.dart --output=build/cli
```

Use `build/cli/bundle/bin/serverpod_sql_check` to test the compiled command.
Format changed Dart files, update the README/changelog, and verify changes with
relevant existing tests. Keep SQL extraction conservative: report unresolved
runtime input instead of claiming it was checked. Preserve source positions,
version isolation and distinct syntax/binding/schema results.

The [README](README.md) documents opt-in database integration and lifecycle tests.
Use only disposable databases. Schema validation uses PREPARE/DEALLOCATE, never
execution of extracted SQL; preparation may execute migrations and an explicit
hook only on checker-owned temporary instances. Keep connection credentials out
of process output and diagnostics, and preserve cleanup on errors/interruption.

Run `dart run tool/check_distribution.dart` from the repository root to check
both publication archives in isolated consumers. Release steps and dependency
order are in the repository's
[release guide](https://github.com/mathis6787/postgresql_parser/blob/main/RELEASING.md).
CI validates macOS/Linux, PostgreSQL 16/17/18, Docker and embedded lifecycle
fixtures. Publishing remains a manual maintainer operation.

