import 'dart:convert';
import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// Generates only the stable bridge ABI, including for a staged major version.
Future<void> generateBindings({
  required int major,
  required Uri header,
  required Uri output,
}) async {
  final symbols = {
    'pgp${major}_parse',
    'pgp${major}_parse_plpgsql',
    'pgp${major}_free_response',
  };
  final generator = FfiGenerator(
    input: Input(entryPoints: [header]),
    output: Output(
      dart: DartOutput(path: output),
      style: NativeExternalBindings(
        assetId: 'package:postgresql_parser/src/native/pg$major.dart',
      ),
      preamble: '// Regenerate with: dart run tool/ffigen.dart\n',
    ),
    visitors: [
      Visitor(
        func: (node) => node.isIncluded = symbols.contains(node.originalName),
        struct: (node) {
          node.isIncluded = node.originalName == 'Pg${major}ParseResponse';
          node.dependencies = CompoundDependencies.full;
        },
      ),
    ],
  );
  await generator.generate();
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('Usage: dart run tool/ffigen.dart [--check]');
    return;
  }
  if (args.isNotEmpty && (args.length != 1 || args.single != '--check')) {
    stderr.writeln('Usage: dart run tool/ffigen.dart [--check]');
    exitCode = 64;
    return;
  }

  final check = args.contains('--check');
  final root = Platform.script.resolve('../');
  final versions = (jsonDecode(
    await File.fromUri(root.resolve('native/versions.json')).readAsString(),
  ) as List).cast<int>();
  final temporary = await Directory.systemTemp.createTemp('pg-bindings-');
  try {
    for (final major in versions) {
      final committed = File.fromUri(
        root.resolve('lib/src/native/pg$major.dart'),
      );
      final generated = File('${temporary.path}/pg$major.dart');
      await generateBindings(
        major: major,
        header: root.resolve('native/pg$major/bridge.h'),
        output: generated.uri,
      );
      final content = await generated.readAsString();
      if (check) {
        if (!committed.existsSync() ||
            await committed.readAsString() != content) {
          stderr.writeln(
            'Bindings for PostgreSQL $major are stale. '
            'Run dart run tool/ffigen.dart.',
          );
          exitCode = 1;
        }
      } else {
        await committed.writeAsString(content);
      }
    }
  } finally {
    await temporary.delete(recursive: true);
  }
}
