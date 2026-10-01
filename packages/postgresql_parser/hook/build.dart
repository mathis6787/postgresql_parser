import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final os = input.config.code.targetOS;
    if (os != OS.macOS && os != OS.linux) {
      throw UnsupportedError(
        'postgresql_parser supports macOS and Linux only.',
      );
    }

    final versionsFile = File.fromUri(
      input.packageRoot.resolve('native/versions.json'),
    );
    output.dependencies.add(versionsFile.uri);
    final versions = (jsonDecode(await versionsFile.readAsString()) as List)
        .cast<int>();
    for (final version in versions) {
      await buildVersion(input, output, os, version);
    }
  });
}

Future<void> buildVersion(
  BuildInput input,
  BuildOutputBuilder output,
  OS os,
  int version,
) async {
  final base = 'native/pg$version/libpg_query';
  final root = input.packageRoot.toFilePath();
  final sourceDirs = ['$base/src', '$base/src/postgres'];
  final sources = <String>[
    'native/pg$version/bridge.c',
    '$base/vendor/protobuf-c/protobuf-c.c',
    '$base/vendor/xxhash/xxhash.c',
    '$base/protobuf/pg_query.pb-c.c',
  ];

  for (final relativeDir in sourceDirs) {
    final directory = Directory.fromUri(
      input.packageRoot.resolve('$relativeDir/'),
    );
    output.dependencies.add(directory.uri);
    sources.addAll(
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.c'))
          .map((file) => file.path.substring(root.length)),
    );
  }
  sources.sort();

  final exportFlags = os == OS.macOS
      ? [
          '-Wl,-exported_symbol,_pgp${version}_parse',
          '-Wl,-exported_symbol,_pgp${version}_free_response',
        ]
      : [
          '-Wl,--version-script=${input.packageRoot.resolve('native/pg$version/exports.map').toFilePath()}',
        ];
  if (os == OS.linux) {
    output.dependencies.add(
      input.packageRoot.resolve('native/pg$version/exports.map'),
    );
  }

  final builder = CBuilder.library(
    name: 'pg_query_$version',
    assetName: 'src/native/pg$version.dart',
    sources: sources,
    includes: [
      base,
      '$base/vendor',
      '$base/src/include',
      '$base/src/postgres/include',
    ],
    flags: [
      '-fno-strict-aliasing',
      '-fwrapv',
      '-fvisibility=hidden',
      ...exportFlags,
    ],
    buildModeDefine: false,
    libraries: os == OS.linux ? const ['m'] : const [],
  );
  await builder.run(input: input, output: output);
}
