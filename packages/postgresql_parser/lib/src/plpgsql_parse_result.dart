import 'postgres_version.dart';

/// PL/pgSQL definitions parsed with a selected PostgreSQL grammar.
///
/// The tree is the upstream JSON list, in definition order. Its fields and
/// supported constructs may differ between PostgreSQL versions.
final class PlpgsqlParseResult {
  const PlpgsqlParseResult({
    required this.version,
    required this.tree,
    required this.rawJson,
  });

  /// The grammar used for this parse.
  final PostgresVersion version;

  /// The decoded upstream definitions; empty when none were found.
  final List<Map<String, dynamic>> tree;

  /// The exact JSON returned by the native parser.
  final String rawJson;
}
