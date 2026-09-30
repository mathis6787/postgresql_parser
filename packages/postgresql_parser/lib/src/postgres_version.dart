/// A PostgreSQL major version supported by this package.
///
/// New constants can be added without changing callers that select a version.
final class PostgresVersion {
  const PostgresVersion._(this.major);

  /// PostgreSQL 17 grammar.
  static const v17 = PostgresVersion._(17);

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
