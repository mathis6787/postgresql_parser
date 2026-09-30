import 'postgres_version.dart';

/// The result of parsing SQL with a selected PostgreSQL grammar.
///
/// [tree] is the upstream parse tree. Its fields may differ between major
/// versions; code that needs the exact upstream representation can use
/// [rawJson].
final class ParseResult {
  const ParseResult({
    required this.version,
    required this.tree,
    required this.rawJson,
  });

  /// The grammar used for this parse.
  final PostgresVersion version;

  /// The decoded JSON parse tree.
  final Map<String, dynamic> tree;

  /// The exact JSON returned by the native parser.
  final String rawJson;
}
