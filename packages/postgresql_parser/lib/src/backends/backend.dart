/// Version-specific native parser contract.
abstract interface class ParserBackend {
  /// Returns the upstream JSON tree or throws a syntax error.
  String parseRaw(String sql);
}
