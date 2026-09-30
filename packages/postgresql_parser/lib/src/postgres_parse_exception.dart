import 'postgres_version.dart';

/// A syntax error reported by the selected PostgreSQL parser.
final class PostgresParseException implements Exception {
  const PostgresParseException({
    required this.version,
    required this.message,
    required this.cursorPosition,
  });

  /// The grammar that rejected the SQL.
  final PostgresVersion version;

  /// The upstream parser's error message.
  final String message;

  /// The upstream cursor position, or zero if none was reported.
  final int cursorPosition;

  @override
  String toString() =>
      'PostgresParseException ($version, position $cursorPosition): $message';
}
