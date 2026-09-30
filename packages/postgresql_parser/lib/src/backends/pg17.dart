import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native/pg17.dart';
import '../postgres_parse_exception.dart';
import '../postgres_version.dart';
import 'backend.dart';

final class Pg17Backend implements ParserBackend {
  const Pg17Backend();

  @override
  String parseRaw(String sql) {
    if (sql.contains('\u0000')) {
      throw ArgumentError('SQL must not contain a NUL character.');
    }

    final nativeSql = sql.toNativeUtf8();
    try {
      final response = pg17Parse(nativeSql);
      if (response == nullptr) {
        throw StateError(
          'PostgreSQL 17 native parser could not allocate a result.',
        );
      }
      try {
        final error = response.ref.errorMessage;
        if (error != nullptr) {
          throw PostgresParseException(
            version: PostgresVersion.v17,
            message: error.toDartString(),
            cursorPosition: response.ref.cursorPosition,
          );
        }

        final tree = response.ref.treeJson;
        if (tree == nullptr) {
          throw StateError(
            'PostgreSQL 17 native parser returned no parse tree.',
          );
        }
        return tree.toDartString();
      } finally {
        pg17FreeResponse(response);
      }
    } finally {
      malloc.free(nativeSql);
    }
  }
}
