/// A PostgreSQL major version supported by this package.
///
/// New constants can be added without changing callers that select a version.
final class PostgresVersion {
  const PostgresVersion._(this.major);

  /// PostgreSQL 17 grammar.
  static const v17 = PostgresVersion._(17);

  // Generated version constants are inserted below by tool/add_postgres_version.dart.
  // BEGIN GENERATED VERSION CONSTANTS
  /// PostgreSQL 18 grammar.
  static const v18 = PostgresVersion._(18);

  /// PostgreSQL 16 grammar.
  static const v16 = PostgresVersion._(16);
  // END GENERATED VERSION CONSTANTS

  /// The PostgreSQL major version number.
  final int major;

  @override
  bool operator ==(Object other) =>
      other is PostgresVersion && other.major == major;

  @override
  int get hashCode => major.hashCode;

  @override
  String toString() => 'PostgreSQL $major';
}
