# postgresql_parser

PostgreSQL SQL and PL/pgSQL parsing for Dart, backed by pinned
[libpg_query](https://github.com/pganalyze/libpg_query) sources.
Supports PostgreSQL 17 and 18 on macOS and Linux.

See the [package README](packages/postgresql_parser/README.md) for installation,
usage, supported platforms, and API limitations.

## Repository layout

| Directory | Purpose |
| --- | --- |
| `packages/postgresql_parser` | The native parser package intended for publication on pub.dev |
| `packages/serverpod_sql_check` | A placeholder for future Serverpod SQL-checking utilities |

This repository uses a Dart pub workspace. The workspace root is not a
publishable package.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, testing, binding generation,
PostgreSQL version maintenance, and release preparation.
