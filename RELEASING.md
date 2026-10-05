# Releasing the packages

Publish from each package directory, never from the private workspace root.
Both packages use MIT for original code; retain the parser's third-party notices.
Publication requires the maintainer's pub.dev account and is a separate manual
step. CI does not publish packages.

## Validate the release

From the repository root:

```sh
dart pub get
dart analyze
dart run tool/check_distribution.dart
```

Then run the package checks:

```sh
cd packages/postgresql_parser
dart run tool/ffigen.dart --check
dart test
cd ../serverpod_sql_check
dart test --concurrency=1 --timeout=3m
```

Require the GitHub Actions checks on macOS/Linux, PostgreSQL 16/17/18, Docker
Serverpod 3.4/4.x, and Serverpod 4 embedded fixtures to pass. Connected tests use
disposable databases and opt-in variables documented in the CLI README.

The distribution check creates publication archives with `--to-archive`; it
never uploads them. It checks the native build inputs through a consumer outside
the workspace and installs the archived CLI with `dart install` into a temporary
Dart data directory. Until the parser is published, only the isolated CLI
fixture's parser dependency source is changed to the extracted local archive.
The original package dependency remains hosted. All scratch files and the
isolated installation are removed afterward.

Inspect the publication file lists. Keep the parser's build hook, generated
bindings, bridges, C sources, registry, source metadata and licenses. Do not
include build output, local package configuration or credentials.

## Publish in dependency order

Update each version and changelog, and set the CLI's parser constraint to the
intended published version. Commit the release changes before publishing.

First, from `packages/postgresql_parser`:

```sh
dart pub publish --dry-run
dart pub publish
```

Wait until the parser version is available on pub.dev. Then, from
`packages/serverpod_sql_check`:

```sh
dart pub publish --dry-run
dart pub publish
```

Do not skip publication validation or force past warnings. Resolve reported
requirements before uploading. A clean dry run does not prove account ownership
of either package name; confirm publication permissions in pub.dev.

Finally test hosted installation in a fresh consumer and install the hosted CLI:

```sh
dart install serverpod_sql_check
serverpod_sql_check --help
```

Keep temporary schema preparation distinct from query validation. A successful
checker result does not certify complete dynamic SQL coverage or Serverpod schema
integrity. Custom schema objects require the explicit setup hook or a prepared
existing database; maintenance helpers do not invoke application startup.

