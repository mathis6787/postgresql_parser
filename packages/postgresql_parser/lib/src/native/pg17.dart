import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The stable wrapper ABI for the PostgreSQL 17 native asset.
final class Pg17NativeResponse extends Struct {
  external Pointer<Utf8> treeJson;
  external Pointer<Utf8> errorMessage;

  @Int32()
  external int cursorPosition;
}

@Native<Pointer<Pg17NativeResponse> Function(Pointer<Utf8>)>(
  symbol: 'pgp17_parse',
)
external Pointer<Pg17NativeResponse> pg17Parse(Pointer<Utf8> sql);

@Native<Void Function(Pointer<Pg17NativeResponse>)>(
  symbol: 'pgp17_free_response',
)
external void pg17FreeResponse(Pointer<Pg17NativeResponse> response);
