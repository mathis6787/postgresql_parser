# postgresql_parser

PostgreSQL SQL and PL/pgSQL parsing for Dart, backed by pinned
[libpg_query](https://github.com/pganalyze/libpg_query) sources.
Supports PostgreSQL 16, 17 and 18 on macOS and Linux.

See the [package README](packages/postgresql_parser/README.md) for installation,
usage, supported platforms, and API limitations.

## Repository layout

| Directory | Purpose |
| --- | --- |
| `packages/postgresql_parser` | The native parser package intended for publication on pub.dev |
| `packages/serverpod_sql_check` | SQL syntax and optional database schema checks, Dart extraction, named binding checks, CLI, and tests |

This repository uses a Dart pub workspace. The workspace root is not a
publishable package.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, testing, binding generation,
PostgreSQL version maintenance, and release preparation.

Original repository code is [MIT licensed](LICENSE). See the parser's
[third-party notices](packages/postgresql_parser/THIRD_PARTY_NOTICES.md) for native
sources and [RELEASING.md](RELEASING.md) for distribution checks and publication.

## Check Serverpod SQL

The [serverpod_sql_check package](packages/serverpod_sql_check/README.md) scans
SQL files and custom SQL in Dart files. From this workspace root:

```sh
dart pub get
dart run serverpod_sql_check --root=/path/to/server --verbose
```

Test and migration directories are excluded by default. Dynamic SQL and parameter maps
that cannot be read statically are reported as skipped.
Inside a Serverpod project, the checker detects the server from its
`pubspec.yaml` dependency on `serverpod`; `--root` overrides discovery.

Add `--database-check` to analyze custom queries against an isolated PostgreSQL
16/17/18 instance, prepared with Serverpod migrations and an optional schema hook.
The checker supports Docker and Serverpod 4 embedded PostgreSQL. Alternatively,
use `--database-target=existing` or supply `SQL_CHECK_DATABASE_URL` to connect to
an existing prepared database. Queries are analyzed with `PREPARE` without
executing their operations. See the CLI package README for configuration,
coverage, and limitations.
