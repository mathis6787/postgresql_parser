import 'dart:io';

/// Exercises publication archives without uploading them or using workspace
/// resolution. The unpublished parser is supplied from its extracted archive.
Future<void> main() async {
  final root = Directory.fromUri(Platform.script.resolve('../'));
  final temporary = await Directory.systemTemp.createTemp(
    'parser-distribution-',
  );
  final sdk = File(Platform.resolvedExecutable).parent.path;
  final environment = <String, String>{
    'DART_DATA_HOME': '${temporary.path}/dart-data',
    'PATH': '$sdk:${Platform.environment['PATH'] ?? ''}',
    'SQL_CHECK_DATABASE_URL': '',
    'DASH__SUPPRESS_ANALYTICS': 'true',
  };

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required String cwd,
    int expectedExit = 0,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: cwd,
      environment: environment,
    );
    if (result.exitCode != expectedExit) {
      throw StateError(
        '$executable ${arguments.join(' ')} exited ${result.exitCode}; '
        'expected $expectedExit.\n${result.stdout}\n${result.stderr}',
      );
    }
    return result;
  }

  try {
    final packages = <String, Directory>{};
    for (final name in ['postgresql_parser', 'serverpod_sql_check']) {
      stdout.writeln('Packaging $name without uploading...');
      final archive = '${temporary.path}/$name.tar.gz';
      await run(Platform.resolvedExecutable, [
        'pub',
        'publish',
        '--to-archive=$archive',
      ], cwd: '${root.path}/packages/$name');
      final extracted = await Directory('${temporary.path}/$name').create();
      await run('tar', ['-xzf', archive, '-C', extracted.path], cwd: root.path);
      for (final required in [
        'LICENSE',
        'CHANGELOG.md',
        'README.md',
        'pubspec.yaml',
      ]) {
        if (!File('${extracted.path}/$required').existsSync()) {
          throw StateError('$name archive is missing $required.');
        }
      }
      if (Directory('${extracted.path}/build').existsSync() ||
          Directory('${extracted.path}/.dart_tool').existsSync()) {
        throw StateError('$name archive contains local build output.');
      }
      packages[name] = extracted;
    }

    final parser = packages['postgresql_parser']!;
    final consumer = await Directory('${temporary.path}/consumer').create();
    await File('${consumer.path}/pubspec.yaml').writeAsString('''
name: distribution_consumer
environment:
  sdk: ^3.13.4
dependencies:
  postgresql_parser:
    path: ${parser.path}
''');
    await Directory('${consumer.path}/bin').create();
    await File('${parser.path}/example/main.dart')
        .copy('${consumer.path}/bin/main.dart');
    stdout.writeln('Running parser consumer outside the workspace...');
    await run(Platform.resolvedExecutable, ['pub', 'get'], cwd: consumer.path);
    final example = await run(Platform.resolvedExecutable, [
      'run',
      'bin/main.dart',
    ], cwd: consumer.path);
    for (final major in [16, 17, 18]) {
      if (!example.stdout.toString().contains(
        'PostgreSQL $major: 2 SQL statements, 1 PL/pgSQL definition.',
      )) {
        throw StateError('Parser example did not exercise PostgreSQL $major.');
      }
    }

    final checker = packages['serverpod_sql_check']!;
    // The parser cannot be resolved from pub.dev before its first publication.
    // Change only this isolated installation fixture's dependency source.
    final manifest = File('${checker.path}/pubspec.yaml');
    final original = await manifest.readAsString();
    final patched = original.replaceFirst(
      RegExp(r'^  postgresql_parser: [^\n]+$', multiLine: true),
      '  postgresql_parser:\n    path: ${parser.path}',
    );
    if (patched == original)
      throw StateError('Cannot stage the parser dependency.');
    await manifest.writeAsString(patched);
    stdout.writeln(
      'Installing archived CLI into an isolated Dart data directory...',
    );
    await run(Platform.resolvedExecutable, [
      'install',
      'serverpod_sql_check@{path: ${checker.path}}',
    ], cwd: temporary.path);
    final executable =
        '${environment['DART_DATA_HOME']}/install/bin/serverpod_sql_check';
    await run(executable, ['--help'], cwd: temporary.path);
    for (final major in [16, 17, 18]) {
      final result = await run(executable, [
        '${checker.path}/example/query.sql',
        '--postgres-version=$major',
      ], cwd: temporary.path);
      if (!result.stdout.toString().contains('0 failed') ||
          !result.stdout.toString().contains(
            'Checked 1 PL/pgSQL definitions',
          )) {
        throw StateError(
          'Installed CLI did not validate SQL and PL/pgSQL for $major.',
        );
      }
    }
    final invalid = File('${temporary.path}/invalid.sql');
    await invalid.writeAsString('SELECT FROM;');
    await run(executable, [invalid.path], cwd: temporary.path, expectedExit: 1);
    stdout.writeln('Distribution checks passed for both publication archives.');
  } finally {
    await temporary.delete(recursive: true);
  }
}
