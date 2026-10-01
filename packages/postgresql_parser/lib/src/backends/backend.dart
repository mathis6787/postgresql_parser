/// Version-specific native parser contract.
abstract interface class ParserBackend {
  /// Returns the upstream JSON tree or throws a syntax error.
  String parseRaw(String sql);

  /// Returns the upstream JSON list of PL/pgSQL definitions or throws an error.
  String parsePlpgsqlRaw(String sql);
}
