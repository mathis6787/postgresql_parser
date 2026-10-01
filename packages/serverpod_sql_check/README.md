# serverpod_sql_check

Static SQL syntax and named parameter binding checks for Dart and Serverpod
projects, using the sibling `postgresql_parser` package. SQL is parsed without
being executed or connecting to a database.

## Run

This package is part of the `postgresql_parser` Dart pub workspace. Run from the
workspace root with Dart 3.13.4+ and a C compiler such as Clang:

```sh
dart pub get
dart run serverpod_sql_check --root=/path/to/server
```

The first run builds the parser's native assets automatically. PostgreSQL 17 is
the default grammar; PostgreSQL 18 is also supported.

```sh
dart run serverpod_sql_check --root=/path/to/server --verbose
dart run serverpod_sql_check --root=/path/to/server --include-migrations
dart run serverpod_sql_check --root=/path/to/server --postgres-version=18
dart run serverpod_sql_check /path/to/query.sql /path/to/service.dart
dart run serverpod_sql_check --help
```

With no paths, the checker scans `--root`, or the current directory if no root is
specified. Explicit paths are relative to the current directory. Migration
folders, generated Dart files, build outputs, and the checker package itself
are excluded by default.

## What is checked

- Complete `.sql` files.
- SQL arguments to Serverpod-style `unsafeQuery` and `unsafeExecute` calls.
- Static SQL templates and standalone CTE helper fragments. CTE fragments are
  completed with `SELECT 1` for syntax checking.
- Named parameter bindings in direct `QueryParameters.named({...})` maps.

Dart extraction supports escaped strings, adjacent strings, concatenation,
interpolation of readable strings, and conditional string branches. Same-file
`const` and non-`late` `final` string initializers are followed through local,
top-level, and class-field references. Lookup respects scope and shadowing;
cycles are skipped. SQL errors point to the original string initializer.

Serverpod `@parameters` are translated into PostgreSQL positional parameters
for parsing. For each raw call, their names are compared with that call's map
keys. Static string keys and same-file string references are supported; map
values can be runtime expressions. Missing names are reported at their original
SQL placeholders, with the available keys listed. Omitted or null parameters
are treated as an empty map. Extra keys are allowed. Parameter-like text inside
SQL comments, quoted strings/identifiers, and dollar-quoted bodies is ignored.

Calls are recognized by their AST names without resolving their Serverpod types.
Syntax validation does not verify database tables, columns, or PL/pgSQL bodies.

## Skipped checks and diagnostics

Runtime expressions, helper returns, mutable string variables, imported values, and
unresolved inherited members remain skipped. Binding checks also skip map
variables, parameter-object variables, dynamic keys, spreads, and collection
`if`/`for` entries; readable SQL still receives syntax validation.

The summary counts SQL variants, syntax failures, skipped SQL candidates, named
parameter sets, missing bindings, and skipped binding checks separately. A
conditional query can yield multiple variants, and a shared template may be
checked more than once. Zero failures applies to the checks that ran; skipped
candidates have an unknown result. `--verbose` prints skipped locations.

Failures print `file:line:column` and a source excerpt with a caret. The additional
`SQL line` and `column` refer to the extracted SQL text. When exact mapping is
unavailable, the diagnostic explicitly says `SQL block starts here`.

Exit codes:

- `0`: completed checks passed; some checks may have been skipped.
- `1`: SQL syntax errors or missing named bindings.
- `2`: invalid options or file access errors.

## Tests

Run from this package directory so the CLI fixture tests find the executable:

```sh
cd packages/serverpod_sql_check
dart test --concurrency=1 --timeout=3m
```

The regression tests cover string resolution, scope and shadowing, source
locations, SQL lexical exclusions, and named parameter bindings.
