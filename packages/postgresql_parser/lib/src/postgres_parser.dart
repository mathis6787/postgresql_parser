import 'dart:convert';

import 'backends/backend.dart';
import 'backends/pg17.dart';
// BEGIN GENERATED BACKEND IMPORTS
import 'backends/pg18.dart';
import 'backends/pg16.dart';
// END GENERATED BACKEND IMPORTS
import 'parse_result.dart';
import 'plpgsql_parse_result.dart';
import 'postgres_parse_exception.dart';
import 'postgres_version.dart';

/// Parses SQL and PL/pgSQL using an explicitly selected PostgreSQL major version.
final class PostgresParser {
  PostgresParser({required this.version})
    : _backend =
          _backends[version.major] ??
          (throw ArgumentError.value(
            version,
            'version',
            'Unsupported version',
          ));

  /// Versions that this package can parse.
  static const supportedVersions = [
    PostgresVersion.v17,
    // BEGIN GENERATED SUPPORTED VERSIONS
    PostgresVersion.v18,
    PostgresVersion.v16,
    // END GENERATED SUPPORTED VERSIONS
  ];

  static const Map<int, ParserBackend> _backends = {
    17: Pg17Backend(),
    // BEGIN GENERATED BACKEND REGISTRY
    18: Pg18Backend(),
    16: Pg16Backend(),
    // END GENERATED BACKEND REGISTRY
  };

  /// The grammar used by this parser.
  final PostgresVersion version;

  final ParserBackend _backend;

  /// Parses one or more SQL statements into the upstream JSON parse tree.
  ///
  /// Throws [PostgresParseException] when the SQL is syntactically invalid.
  ParseResult parse(String sql) {
    final rawJson = _backend.parseRaw(sql);
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Native parser returned an unexpected JSON tree.');
    }
    return ParseResult(version: version, tree: decoded, rawJson: rawJson);
  }

  /// Parses PL/pgSQL definitions in a SQL script into the upstream JSON list.
  ///
  /// Accepts complete `CREATE FUNCTION`, `CREATE PROCEDURE`, and `DO`
  /// statements. Bare procedural bodies must be wrapped by the caller.
  /// Ordinary SQL statements do not produce entries. Supported constructs and
  /// output fields follow the selected upstream version.
  ///
  /// Throws [PostgresParseException] for upstream parsing errors. Cursor
  /// positions are preserved as reported; they may refer to a function body
  /// rather than the entire script, or be zero when unavailable.
  ///
  /// This does not execute code, validate database objects or runtime behavior,
  /// or inspect dynamically constructed SQL.
  PlpgsqlParseResult parsePlpgsql(String sql) {
    final rawJson = _backend.parsePlpgsqlRaw(sql);
    final decoded = jsonDecode(rawJson);
    if (decoded is! List ||
        decoded.any((entry) => entry is! Map<String, dynamic>)) {
      throw StateError('Native parser returned an unexpected PL/pgSQL tree.');
    }
    return PlpgsqlParseResult(
      version: version,
      tree: decoded.cast<Map<String, dynamic>>(),
      rawJson: rawJson,
    );
  }
}
