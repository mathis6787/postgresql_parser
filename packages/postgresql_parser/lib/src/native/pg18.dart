import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The stable wrapper ABI for the PostgreSQL 18 native asset.
final class Pg18NativeResponse extends Struct {
  external Pointer<Utf8> treeJson;
  external Pointer<Utf8> errorMessage;

  @Int32()
  external int cursorPosition;
}

@Native<Pointer<Pg18NativeResponse> Function(Pointer<Utf8>)>(
  symbol: 'pgp18_parse',
)
external Pointer<Pg18NativeResponse> pg18Parse(Pointer<Utf8> sql);

@Native<Void Function(Pointer<Pg18NativeResponse>)>(
  symbol: 'pgp18_free_response',
)
external void pg18FreeResponse(Pointer<Pg18NativeResponse> response);
