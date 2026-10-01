import 'dart:convert';

import 'backends/backend.dart';
import 'backends/pg17.dart';
// BEGIN GENERATED BACKEND IMPORTS
// END GENERATED BACKEND IMPORTS
import 'parse_result.dart';
import 'postgres_parse_exception.dart';
import 'postgres_version.dart';

/// Parses SQL using an explicitly selected PostgreSQL major version.
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
    // END GENERATED SUPPORTED VERSIONS
  ];

  static const Map<int, ParserBackend> _backends = {
    17: Pg17Backend(),
    // BEGIN GENERATED BACKEND REGISTRY
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
}
