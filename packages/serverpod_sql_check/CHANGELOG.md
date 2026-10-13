# Changelog

## 0.1.1

- Add a runnable Dart example with realistic SQL and intentionally invalid SQL
  and PL/pgSQL statements demonstrating checker diagnostics.
- Check source SQL around standalone psql `\gexec` commands in SQL files and Dart
  templates, preserving diagnostic locations. Visibly skip unsupported psql
  scripts; retain syntax errors for psql commands in direct database calls.
- Reconstruct constant `\gexec` output from SQL strings, concatenation and
  `format()`, then check its SQL and PL/pgSQL syntax. Report unknown outputs
  separately, preserve source expression locations and use versioned identifier
  quoting rules without executing source or generated commands.

## 0.1.0

- Discover Serverpod server packages and scan SQL files and custom SQL in Dart.
- Resolve supported static imports, helpers, builders and finite query variants.
- Check SQL, PL/pgSQL definitions and named parameter bindings; report skipped checks.
- Optionally analyze supported queries against PostgreSQL 16, 17 and 18 with PREPARE.
- Support existing databases and isolated Docker or Serverpod 4 embedded instances.
- Prepare temporary schemas with Serverpod 3.4/4.x migrations and phased setup hooks.

