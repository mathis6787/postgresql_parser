import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native/pg17.dart';
import '../postgres_parse_exception.dart';
import '../postgres_version.dart';
import 'backend.dart';

final class Pg17Backend implements ParserBackend {
  const Pg17Backend();

  @override
  String parseRaw(String sql) => _parseRaw(sql, pgp17_parse);

  @override
  String parsePlpgsqlRaw(String sql) => _parseRaw(sql, pgp17_parse_plpgsql);

  String _parseRaw(
    String sql,
    Pointer<Pg17ParseResponse> Function(Pointer<Char>) parse,
  ) {
    if (sql.contains('\u0000')) {
      throw ArgumentError('SQL must not contain a NUL character.');
    }

    final nativeSql = sql.toNativeUtf8();
    try {
      final response = parse(nativeSql.cast<Char>());
      if (response == nullptr) {
        throw StateError(
          'PostgreSQL 17 native parser could not allocate a result.',
        );
      }
      try {
        final error = response.ref.error_message;
        if (error != nullptr) {
          throw PostgresParseException(
            version: PostgresVersion.v17,
            message: error.cast<Utf8>().toDartString(),
            cursorPosition: response.ref.cursor_position,
          );
        }

        final tree = response.ref.tree_json;
        if (tree == nullptr) {
          throw StateError(
            'PostgreSQL 17 native parser returned no parse tree.',
          );
        }
        return tree.cast<Utf8>().toDartString();
      } finally {
        pgp17_free_response(response);
      }
    } finally {
      malloc.free(nativeSql);
    }
  }
}
