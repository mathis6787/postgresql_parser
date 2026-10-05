# serverpod_sql_check

Static SQL, PL/pgSQL, and named parameter binding checks for Dart and Serverpod
projects, using the `postgresql_parser` package. By default, SQL is
parsed without being executed or connecting to a database. An optional mode
also analyzes supported queries against a prepared test database schema.

## Install and run

Requires Dart 3.13.4+ and macOS or Linux with a C compiler (Xcode command line
tools on macOS, Clang on Linux). Windows and web are unsupported.

Install the command from pub.dev:

```sh
dart install serverpod_sql_check
serverpod_sql_check
```

Follow Dart's installation output to add its executable directory to `PATH`.
Installation compiles and bundles the parser's native libraries. libclang and
ffigen are not needed by users. Temporary database preparation also requires a
Dart SDK on `PATH` for project helper processes.

To use the checker as a development dependency instead:

```sh
dart pub add --dev serverpod_sql_check
dart run serverpod_sql_check --root=/path/to/server
```

For development from this repository, run from the workspace root:

```sh
dart pub get
dart run serverpod_sql_check --root=/path/to/server
```

The first run builds the parser's native assets automatically. PostgreSQL 17 is
the default grammar; PostgreSQL 16 and 18 are also supported.

```sh
dart run serverpod_sql_check --root=/path/to/server --verbose
dart run serverpod_sql_check --root=/path/to/server --include-migrations
dart run serverpod_sql_check --root=/path/to/server --include-tests
dart run serverpod_sql_check --root=/path/to/server --postgres-version=18
dart run serverpod_sql_check /path/to/query.sql /path/to/service.dart
dart run serverpod_sql_check --help
```

Try the [sample SQL script](example/query.sql) with
`serverpod_sql_check /path/to/example/query.sql`. Parsing never executes its
procedural body.

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

## Optional database validation

Syntax checking accepts `SELECT label FROM productz;` even if `productz` does
not exist. Database mode asks PostgreSQL to analyze supported statements against
the installed schema and catches missing tables, renamed columns, unknown
functions, and incompatible types.

Without a connection URL, `--database-check` creates an **isolated temporary
PostgreSQL instance**, prepares the project's schema, validates queries and
removes its instance. PostgreSQL 16/17/18 are supported; offline checking still
defaults to PostgreSQL 17.

```sh
serverpod_sql_check --database-check
serverpod_sql_check --database-check --database-backend=embedded
serverpod_sql_check --database-check --database-backend=docker
serverpod_sql_check --database-check --database-docker-image=postgres:17
serverpod_sql_check --database-check --database-setup=tool/sql_check_database.dart
```

The server package follows the usual discovery and `--root` rules. Temporary
setup defaults to `config/test.yaml`; `--database-mode=development` selects the
other local configuration. There is no fallback to a different mode.
`SERVERPOD_DATABASE_*` values override YAML. Passwords follow shared, mode,
`SERVERPOD_DATABASE_PASSWORD`, then `SERVERPOD_PASSWORD_database` precedence.

| Option | Behavior |
| --- | --- |
| `--database-target=temporary` | Isolated instance; conflicts with a populated URL variable |
| `--database-target=existing` | Prepared project database; defaults to development |
| `--database-backend=auto` | Temporary backend: embedded with `dataPath`, otherwise Docker |
| `--database-backend=embedded` or `docker` | Explicit temporary backend |
| `--database-mode=test` or `development` | Project configuration mode |
| `--database-docker-image=<image>` | Temporary Docker image override |
| `--database-setup=<file.dart>` | Temporary preparation before and after migrations |
| `--database-url-env=<name>` | Existing prepared database URL variable |
| `--database-search-path=<value>` | Explicit search path override |

Embedded setup uses the project's resolved Serverpod 4 dependencies and their
published PostgreSQL bundle (currently 16.13). The first launch may download
binaries into Serverpod's shared cache. Each invocation gets a separate data
directory; the project's normal `dataPath` is never initialized or modified.

Docker setup identifies the Compose service by its configured database name or
published port and reuses only its image. Ambiguous services or build-only
configurations require `--database-docker-image`. Its dedicated container has
random credentials, a random localhost port and no project volume or custom
service command. Docker must already be available; the checker does not start
Docker Desktop or other Compose services.

For a Compose service using only `build:`, provide the name of its built image,
for example `--database-docker-image=my_server-postgres_test`. Build that image
with Docker or Compose first. The checker uses an image already present locally;
it pulls the image only when missing. This preserves extensions installed by a
custom Dockerfile. The checker does not build project Dockerfiles automatically.
Installing extension binaries in the image does not enable those extensions in
the fresh database. Use the setup hook for `CREATE EXTENSION`, custom generated
columns, indexes and other objects created by application startup. Missing
objects cause schema errors even when the same SQL works in a prepared database.

Automatic migrations support Serverpod 3.4 and 4.x. Run `dart pub get` and
`serverpod generate`, and create the project's migrations beforehand. Helpers
use the project's resolved dependencies and generated Protocol/Endpoints, in
maintenance mode against the temporary database. They do not import application
startup, start API servers or Redis, execute future calls, or apply repairs.
Initialization follows Serverpod's migration mechanism; objects added only in
historical `migration.sql` files may need the hook on a freshly initialized base.

The optional Dart setup script runs from the server directory twice, with
`--phase=before-migrations` and `--phase=after-migrations`. It receives the
**temporary** connection through `SQL_CHECK_DATABASE_URL`. Use the first phase
for extensions or schemas required by migrations and the second for custom
objects:

```dart
import 'dart:io';
import 'package:postgres/postgres.dart';

Future<void> main(List<String> args) async {
  final db = await Connection.openFromUrl(
    Platform.environment['SQL_CHECK_DATABASE_URL']!,
  );
  try {
    if (args.single == '--phase=before-migrations') {
      await db.execute('CREATE SCHEMA custom');
    } else {
      await db.execute('CREATE TABLE custom.audit (id bigint PRIMARY KEY)');
    }
  } finally {
    await db.close();
  }
}
```

For an **existing prepared database**:

```sh
serverpod_sql_check --database-check --database-target=existing
serverpod_sql_check --database-check --database-target=existing --database-mode=test
serverpod_sql_check --database-check --database-url-env=MY_TEST_DATABASE_URL
```

A populated `SQL_CHECK_DATABASE_URL`, or the explicitly selected variable,
retains the previous URL-based behavior and takes priority over automatic
connection discovery, including the project mode. An explicitly selected variable must be populated;
combining a URL with an explicit temporary target is an error.
Without a URL, existing mode reads the project configuration and attaches to a
running embedded instance or connects through configured TCP coordinates.
It never starts, migrates, prepares or deletes that database. Start Serverpod or
`serverpod database start` if the embedded instance is stopped. Supply a URL for
connection configuration replaced by application Dart code.

URLs and passwords are not printed. The report shows the target, backend, mode,
server/parser versions, effective role/search path and separate startup,
preparation and validation durations. An explicit search path wins over project
configuration; URL-only mode retains the role's path unless overridden. Changes
use a parameterized command. Unsupported majors and explicit parser mismatches
fail with code 2. Backend, image and setup options require a temporary target.

Preparation can execute migrations and the explicit hook **only on the isolated
instance**. Preparation stages have a 120-second limit; downloads/pulls have a
five-minute limit. Cleanup closes connections and removes only checker-owned
resources, including on SIGINT/SIGTERM; failures are operational errors.
Temporary schemas do not reproduce another database's manual changes, data or
role grants. Use a prepared database when those differences matter.

A successful checker result applies only to covered queries. It does not mean
Serverpod's full schema verification passed: PREPARE does not validate every
index or constraint. Check the exit status of schema preparation separately.
In CI, use `prepare-command && serverpod_sql_check --database-check ...` so a
preparation failure cannot be hidden by a successful checker run. Application
initializers after `pod.start()` are not run by the temporary maintenance helper
and may be skipped by a maintenance invocation of the application itself. Put
custom schema setup in the explicit hook rather than relying on application
startup. If the generated schema expects those objects during migration
verification, they must already exist at that point; an after-migrations hook
cannot repair an earlier verification failure.

Schema checks cover statically resolved `unsafeQuery` and `unsafeExecute` calls
and complete statements in `.sql` files. The checker uses the native parse tree
to isolate statements and permits only `SELECT`, `VALUES`, `INSERT`, `UPDATE`,
`DELETE`, and `MERGE` without `SELECT INTO`. It sends `PREPARE`, then `DEALLOCATE`,
using the extended protocol to reject multiple top-level commands. It never sends
the scanned queries for execution, `EXECUTE`, or `EXPLAIN ANALYZE`. The session is
read-only, with a 10-second connection limit and a 5-second command limit.
Automatic configuration modes are restricted to test and development.

Repeated named parameters such as `@id` become the same positional parameter.
Existing `$1` parameters are preserved. PostgreSQL infers parameter types where
possible; indeterminate types and mixed named/positional conventions are reported
as **not covered**, without fabricated values. `unsafeQuery` calls with several
statements fail. `unsafeExecute` without parameters permits multiple statements,
matching the driver's simple-protocol behavior; supported statements in those
batches and `.sql` scripts are checked separately. Parameterized raw calls still
require a single statement. DDL and procedural statements in batches remain
syntax-only and are never executed by validation.

Constants and fragments not used in raw calls remain syntax-only. DDL, `DO`,
`CALL`, `COPY`, and PL/pgSQL definitions are not validated against the schema or
executed. Dynamic SQL that cannot be extracted remains unchecked. Including
migration files checks supported queries against the already prepared schema,
not against each intermediate migration state.

The existing syntax, PL/pgSQL, and binding summaries remain separate from the
database summary. `--verbose` distinguishes `OK SYNTAX`, `OK DATABASE`, and
`SKIP DATABASE`; schema errors include PostgreSQL's SQLSTATE and original source
location. Identical statements share a preparation, but retain diagnostics at
each occurrence. The report shows database time and the number of unique
preparations; a timeout or lost connection makes validation incomplete.

Passing schema validation does not guarantee results, constraints depending on
data, all execution permissions, or PL/pgSQL branches. Integration tests remain
necessary for runtime behavior.

A small local macOS fixture with 200 raw calls and 20 distinct queries took
approximately 42 ms offline and 95 ms connected to PostgreSQL 17 in Docker
(median of three runs after warmup). Coverage was identical, and only 20
preparations were needed. This excludes database startup and schema setup; the
added cost depends on query count and database latency.

A macOS Serverpod 4 fixture with system migrations and the phased custom-schema
hook took about 32 seconds to prepare with an empty embedded binary cache
(20 seconds startup/download and 12 seconds preparation), and 21 seconds with
that cache reused (7 seconds startup and 14 seconds preparation). These single
runs include compiling the project's Dart helpers; the cold run uses a private
cache rather than clearing the project's cache. Network, framework size and
machine load affect these figures. The CLI reports each duration separately.

For programmatic CLI use, `checkSql(arguments)` now returns `Future<void>`;
await it before reading `exitCode` or terminating the process.

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
- `1`: SQL syntax errors, PL/pgSQL body errors, missing named bindings, or
  database statement errors.
- `2`: invalid options, missing or ambiguous server discovery, file access
  errors, database configuration/version errors, or interrupted database checks.

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
side effects, and original fragment locations on all supported PostgreSQL versions.

Database integration tests require `SQL_CHECK_TEST_DATABASE_URL` pointing to a
disposable PostgreSQL 16/17/18 database. The fixture connection needs privileges to
create and remove a dedicated schema and login role; the CLI uses that separate
role and a read-only session. Without the variable, these integration tests are
skipped and the ordinary suite needs no database.

```sh
dart test test/database_check_test.dart test/database_integration_test.dart \
  --concurrency=1 --timeout=3m
```

CI runs these tests on PostgreSQL 16, 17 and 18, including schema failures, source
mapping, parameter handling, cleanup, timeouts, and unchanged data after checking
write statements.

Database lifecycle tests are opt-in and prepare isolated fixture projects:

```sh
SQL_CHECK_TEST_LIFECYCLE=1 SQL_CHECK_TEST_BACKEND=docker \
  SQL_CHECK_TEST_SERVERPOD=3.4.13 dart test test/database_lifecycle_test.dart --timeout=10m
SQL_CHECK_TEST_LIFECYCLE=1 SQL_CHECK_TEST_BACKEND=embedded \
  SQL_CHECK_TEST_SERVERPOD=4.0.2 dart test test/database_lifecycle_test.dart --timeout=10m
```

Docker fixtures default to PostgreSQL 16; set `SQL_CHECK_TEST_DOCKER_IMAGE` and
`SQL_CHECK_TEST_MAJOR` together for 17/18. These tests require Dart on PATH and
may resolve fixture dependencies or download embedded binaries. Ordinary tests
need no database, Docker or additional project dependencies.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and release checks.
Original CLI code is licensed under [MIT](LICENSE). The native parser dependency
retains its own third-party notices.
