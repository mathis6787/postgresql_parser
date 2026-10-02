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
dart run serverpod_sql_check --root=/path/to/server --include-tests
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
Test folders (`test/` and `integration_test/`), migration folders, generated Dart
files, build outputs, and the checker package itself are excluded from scanning
by default. Use `--include-tests` to check SQL in test folders, including test
setup and cleanup queries. Intentionally invalid SQL in tests is reported as a
failure. This option is also required when passing a test file or directory
explicitly; `--include-migrations` independently enables migration SQL.

## What is checked

- Complete `.sql` files.
- PL/pgSQL bodies in `CREATE FUNCTION`, `CREATE PROCEDURE`, and `DO` statements.
- SQL arguments to Serverpod-style `unsafeQuery` and `unsafeExecute` calls.
- Static SQL templates and standalone CTE helper fragments. A fragment can end
  after a CTE, after a separating comma, or at a bare `WITH` prefix. A dummy
  query (and CTE when needed) completes it for syntax checking. Raw query calls
  still require a complete statement.
- Named parameter bindings supplied through `QueryParameters.named(...)`.

Dart extraction supports escaped strings, adjacent strings, concatenation,
interpolation of readable strings, conditional branches, and switch expressions.
Every switch case must have a readable result; pattern-bound runtime values
remain unknown. Same-file
`const` and non-`late` `final` string initializers are followed through local,
top-level, and safe class-field references. Instance fields require a readable
concrete receiver or a member that cannot be overridden in its library.
Relative imports, `package:` imports, import prefixes, re-exports, and
`show`/`hide` combinators are supported for
readable top-level initializers and static class fields. Package imports use the
project's `.dart_tool/package_config.json`; run `dart pub get` to create it.
Referenced files are read even when they are outside the selected scan paths.

Synchronous helpers can return readable SQL through expression bodies,
`return` statements, local declarations and assignments, `if`/`else` branches,
and switch statements with readable cases.
Top-level functions, local functions, and static methods are supported. Calls to
private instance helpers on implicit or explicit `this`, and public helpers on
`this` in final classes, are also supported when no other declaration in the
library can override that member. Libraries with parts and unknown receivers
remain unresolved. Readable
string arguments and optional string defaults can be substituted. For example,
both possible outputs of this helper are checked:

```dart
String buildQuery(Filters filters) {
  if (filters.onlyActive) {
    return 'SELECT * FROM equipment WHERE active = true';
  }
  return 'SELECT * FROM equipment';
}

// The runtime filter value is not needed to check these two SQL shapes.
session.db.unsafeQuery(buildQuery(filters));
```

Every reachable return must be readable and each path must return a value.
Branch expansion is limited to 32 variants. Helpers are inspected without
executing application code. Lookup respects scope, shadowing, and readable base
class/mixin declarations; cycles and ambiguous references are skipped. SQL errors
point to the original initializer, helper return, or argument fragment, including
fragments in other files. Named bindings are checked against each resolved query
at its call site.

Readable top-level and static getters are followed in the same way. Constant
object registries can supply SQL fragments through their fields and getters.
String operations include case conversion, trimming, literal `replaceAll` and
`replaceFirst`, `substring`, `split`, and readable string predicates. Runtime
patterns and unreadable string arguments remain unknown.

For a private function or unique private method in a library without parts,
the checker also follows every direct call to supply its arguments. Local
functions can use their lexical callers. Positional, named, and default arguments
can carry SQL, records, objects, and parameter maps together. An unreadable call,
tear-off, recursive call, or unresolved private selector keeps the entry point
unknown. Public entry points retain unknown arguments because callers outside
the scanned source can supply other values.

```dart
void _execute(dynamic session, String sql, Map<String, Object?> parameters) {
  session.db.unsafeQuery(sql, parameters: QueryParameters.named(parameters));
}

void example(dynamic session, Object equipmentId) {
  _execute(session, 'SELECT * FROM equipment WHERE id = @id', {'id': equipmentId});
}
```

Typed enum parameters can be expanded into their declared values, including
`null` for nullable enums. Repeated uses of the same parameter stay on the same
path. Equivalent helper results are merged only when caller values and mutable
aliases agree, so unrelated helper branches do not repeatedly consume the SQL
expansion budget.

Before each query, the checker follows the local values that affect its SQL or
parameter keys. Unrelated return values and parameter-map values do not consume
the variant budget. Their possible side effects are still accounted for;
an unreadable call that can change a needed collection leaves it unresolved.

Local string variables can also be followed through assignments, concatenation,
and `if`/`else` branches before the query call:

```dart
var where = '';
if (onlyActive) where = 'WHERE active = true';
session.db.unsafeQuery('SELECT * FROM equipment $where');
```

Both SQL shapes are checked. Values are taken at their use location, so a later
assignment does not change an earlier check. Captured writes in closures and
unreadable assignments leave the affected value unresolved.

Lists support readable spreads, conditional entries, `add`, `addAll`, indexed
updates, and `join`. `StringBuffer` supports initial content, `write`, `writeln`,
`writeAll`, `clear`, and `toString`, including cascades. Finite `for` loops and
collection `for` entries can assemble strings from readable collections, enum
values, or bounded integer ranges. Every reachable iteration is checked; an
unknown collection or an unbounded loop remains unresolved.

Readable map `keys`, `values`, and `entries` views retain their live source.
Finite `map` and `where` callbacks, `toList`, and `toSet` can project readable
collections. An unknown filter over a known finite list checks its possible
subsets, within the variant limit. `firstWhere` and `singleWhere` can select
readable registry entries; a directly throwing `orElse` is a path that never
reaches the query. Lazy mapped `length` does not invoke its callback, and mapped
`first`, `last`, and `single` evaluate only the selected element. Unknown callback
effects and unsupported partial filtering remain unresolved.
`Map.from`, `Map.of`, `Map.unmodifiable`, `List.from`, and `List.of` support
readable copies and preserve shallow collection aliases.

```dart
final clauses = <String>['SELECT * FROM equipment'];
if (onlyActive) clauses.add('WHERE active = @active');
session.db.unsafeQuery(
  clauses.join(' '),
  parameters: QueryParameters.named({if (onlyActive) 'active': true}),
);
```

Records and readable objects can carry SQL and parameter maps together. Supported
objects use final fields and simple generative constructors with readable
defaults and initializers. Their getters and concrete instance helpers can
project or assemble readable values:

```dart
final statement = (
  text: 'SELECT * FROM equipment WHERE id = @id',
  parameters: QueryParameters.named({'id': equipmentId}),
);
session.db.unsafeQuery(statement.text, parameters: statement.parameters);
```

Readable factory bodies and simple factory redirects are followed. Generative
constructors require an empty body and readable field initialization. Inherited
object implementations remain unresolved. Without a concrete receiver, safe
private members or members of a final class can use immutable declaration
initializers; constructor arguments are never guessed. Enum `values`, `name`,
`index`, readable fields, and simple enum helpers are supported. Application code
is never run.
Fragments consumed by list or buffer assembly are checked through the completed
query rather than treated as separate SQL statements.

Serverpod `@parameters` are translated into PostgreSQL positional parameters
for parsing. For each raw call, their names are compared with that call's map
keys. Static string keys, readable string references, constant maps, known
spreads, and local map variables are supported; map values can be runtime
expressions. Local map tracking supports subscript assignments, `addAll`,
`remove`, `clear`, replacement, and finite branches and loops. Readable aliases
retain shared collection identity. Passing a mutable collection to an unknown
helper or making an unknown mutation leaves its contents unresolved.
For a fresh map literal with fixed string keys, runtime branches in the values
do not prevent checking those keys. A readable `QueryParameters.named` wrapper
can be reused between recognised `session.db.unsafeQuery` and `unsafeExecute`
calls; arbitrary helpers can still make its bindings unknown.

Conditional entries and mutations distinguish guaranteed keys from possible
keys. An unrelated conditional key does not prevent checking guaranteed
bindings. A definitely absent required key fails; a required key that is only
conditional leaves the binding check skipped. SQL and map paths share known
conditions on local values, including negation. The example above therefore
checks the `active` binding only for the SQL variant that uses it. Reassigning a
condition, reading an arbitrary runtime property, or invoking a runtime method
does not establish that two conditions have the same result. Missing names are
reported at their original SQL placeholders, with the available keys listed.
Omitted or null parameters
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

Runtime SQL fragments, mutable fields or globals, `late` variables, unresolved
imports, conditional imports/exports, and unresolved inherited members remain
skipped. Helpers with asynchronous bodies, unsupported statements, unbounded
loops, or unknown return values are skipped. Instance calls whose
implementation cannot be determined remain skipped. Binding checks also skip
dynamic keys, unknown spreads, escaping maps,
and required conditional keys that cannot be tied to the SQL path; readable SQL
still receives syntax validation. Expansion is bounded to 32 paths and 32
iterations per loop; exceeding the limit leaves the query unchecked instead of
checking only a subset.

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
The compiled CLI tests also cover imported SQL, package configuration, aliases,
re-exports, helper branches, call bindings, cross-file error locations, and
conservative handling of unknown or ambiguous source.
They also cover records and constructor fields, collection and buffer assembly,
finite loops, helper assignments and switches, correlated bindings, aliases,
side effects, and original fragment locations on both PostgreSQL versions.
