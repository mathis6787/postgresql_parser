# serverpod_sql_check

Static SQL, PL/pgSQL, and named parameter binding checks for Dart and Serverpod
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

When the executable is on your `PATH`, run it anywhere inside a Serverpod project:

```sh
serverpod_sql_check
```

Server packages are identified by a `serverpod` entry under `dependencies` in
`pubspec.yaml`, regardless of their folder names.

| Where you run it | Default behavior |
| --- | --- |
| Server directory or its subfolders | Scan the entire enclosing server package |
| Project root, client, or Flutter package | Find and scan the server package in the project |
| Outside a Serverpod project | Require `--root=/path/to/server` |
| Project with multiple servers | List the servers and require `--root` |

An enclosing server takes priority even if its project contains other servers.
Discovery searches within the nearest Git root or Dart workspace. Projects
without either marker are identified by a server package directly inside the
project root, alongside the client and Flutter packages. Build and cache
directories and symbolic links are excluded from the search.

`--root` always overrides discovery and accepts a relative or absolute directory:

```sh
serverpod_sql_check --root=/path/to/server
```

Explicit file or directory arguments also bypass discovery and are relative to
the current directory. With both positional paths and `--root`, only the
positional paths are scanned; `--root` controls relative diagnostic paths.
Explicit roots can also scan SQL in directories without a Serverpod dependency.
Migration folders, generated Dart files, build outputs, and the checker package
itself are excluded from scanning by default.

## What is checked

- Complete `.sql` files.
- PL/pgSQL bodies in `CREATE FUNCTION`, `CREATE PROCEDURE`, and `DO` statements.
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
Syntax validation does not verify database tables, columns, or runtime behavior.

## PL/pgSQL checks

PL/pgSQL checking runs automatically after the outer SQL passes syntax parsing.
Functions and procedures with `LANGUAGE plpgsql` and `DO` blocks with the
default or explicit PL/pgSQL language are checked using the selected PostgreSQL
version. This applies to SQL files and statically readable Dart SQL strings.
Migration files receive the same checks when `--include-migrations` is set.

For example, this script now fails because the procedural body is invalid:

```sql
DO $$
BEGIN
  IF THEN
    RAISE NOTICE 'missing condition';
  END IF;
END;
$$;
```

Each definition is checked separately, so a script can report multiple bad
bodies. Definitions in other languages receive the existing outer SQL check.
Text inside strings and comments does not trigger procedural checking. Serverpod
named parameters are not rewritten or checked inside quoted procedural bodies.

PL/pgSQL support follows the pinned upstream parser; it does not execute code,
inspect dynamically constructed SQL, or provide full database-side function
validation. Bare procedural bodies must be wrapped in a complete definition or
`DO` statement.

## Skipped checks and diagnostics

Runtime expressions, helper returns, mutable string variables, imported values, and
unresolved inherited members remain skipped. Binding checks also skip map
variables, parameter-object variables, dynamic keys, spreads, and collection
`if`/`for` entries; readable SQL still receives syntax validation.

The summary counts SQL variants, syntax failures, PL/pgSQL definitions and body
failures, skipped SQL candidates, named parameter sets, missing bindings, and
skipped binding checks separately. A
conditional query can yield multiple variants, and a shared template may be
checked more than once. Zero failures applies to the checks that ran; skipped
candidates have an unknown result. `--verbose` prints skipped locations.

Failures print `file:line:column` and a source excerpt with a caret. The additional
`SQL line` and `column` refer to the extracted SQL text. When exact mapping is
unavailable, the diagnostic explicitly says `SQL block starts here`.

PL/pgSQL failures are labeled `PL/pgSQL` and point to the definition's source
block, including the original initializer of a referenced Dart string. Their
diagnostics say `PL/pgSQL block starts here`: upstream body-relative positions
are not interpreted as positions in the full SQL script. A positive upstream
position is printed separately when available. A variant with one or more body
errors counts once in SQL variant failures and each bad definition counts in
the PL/pgSQL failure summary.

Exit codes:

- `0`: completed checks passed; some checks may have been skipped.
- `1`: SQL syntax errors, PL/pgSQL body errors, or missing named bindings.
- `2`: invalid options, missing or ambiguous server discovery, or file access errors.

## Tests

Run from this package directory so the CLI fixture tests find the executable:

```sh
cd packages/serverpod_sql_check
dart test --concurrency=1 --timeout=3m
```

The regression tests cover string resolution, scope and shadowing, source
locations, SQL lexical exclusions, named parameter bindings, and PL/pgSQL
definitions, mixed-language scripts, and migration inclusion on both grammars.
Discovery tests cover server, client, Flutter, and project directories, multiple
servers, explicit overrides, and execution from outside a Serverpod project.
