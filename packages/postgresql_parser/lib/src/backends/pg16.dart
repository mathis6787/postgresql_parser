import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native/pg16.dart';
import '../postgres_parse_exception.dart';
import '../postgres_version.dart';
import 'backend.dart';

final class Pg16Backend implements ParserBackend {
  const Pg16Backend();

  @override
  String parseRaw(String sql) => _parseRaw(sql, pgp16_parse);

  @override
  String parsePlpgsqlRaw(String sql) => _parseRaw(sql, pgp16_parse_plpgsql);

  String _parseRaw(
    String sql,
    Pointer<Pg16ParseResponse> Function(Pointer<Char>) parse,
  ) {
    if (sql.contains('\u0000')) {
      throw ArgumentError('SQL must not contain a NUL character.');
    }

    final nativeSql = sql.toNativeUtf8();
    try {
      final response = parse(nativeSql.cast<Char>());
      if (response == nullptr) {
        throw StateError(
          'PostgreSQL 16 native parser could not allocate a result.',
        );
      }
      try {
        final error = response.ref.error_message;
        if (error != nullptr) {
          throw PostgresParseException(
            version: PostgresVersion.v16,
            message: error.cast<Utf8>().toDartString(),
            cursorPosition: response.ref.cursor_position,
          );
        }

        final tree = response.ref.tree_json;
        if (tree == nullptr) {
          throw StateError(
            'PostgreSQL 16 native parser returned no parse tree.',
          );
        }
        return tree.cast<Utf8>().toDartString();
      } finally {
        pgp16_free_response(response);
      }
    } finally {
      malloc.free(nativeSql);
    }
  }
}
