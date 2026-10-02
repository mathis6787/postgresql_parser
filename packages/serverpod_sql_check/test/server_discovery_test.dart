import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_sql_check/src/server_discovery.dart';
import 'package:test/test.dart';

import 'imports_and_helpers.dart';
import 'finite_flow.dart';
import 'static_assembly.dart';
import 'static_contexts.dart';
import 'static_demand.dart';
import 'static_getters.dart';
import 'static_strings.dart';
import 'static_object_safety.dart';

void main() {
  late Directory fixture;

  Directory directory(String path) =>
      Directory(p.join(fixture.path, path))..createSync(recursive: true);

  Directory package(String path, [String dependencies = 'serverpod: ^3.0.0']) {
    final result = directory(path);
    File(p.join(result.path, 'pubspec.yaml'))
        .writeAsStringSync('name: fixture\ndependencies:\n  $dependencies\n');
    return result;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('server_discovery_');
    fixture = Directory(fixture.resolveSymbolicLinksSync());
    directory('.git');
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'server dependency, rather than a folder suffix, identifies the server',
    () {
      final server = package('backend');
      package('app_server', 'serverpod_client: ^3.0.0');
      expect(discoverServer(fixture).path, server.path);
    },
  );

  test(
    'detects from server, project, client, Flutter, and their subfolders',
    () {
      final server = package('backend');
      final client = package('project_client', 'serverpod_client: ^3.0.0');
      final flutter = package('project_flutter', 'flutter: {sdk: flutter}');
      for (final start in [
        server,
        directory('backend/lib/src'),
        fixture,
        directory('docs/examples'),
        client,
        directory('project_client/lib/src'),
        flutter,
        directory('project_flutter/lib/screens'),
      ]) {
        expect(discoverServer(start).path, server.path, reason: start.path);
      }
    },
  );

  test('enclosing server takes priority over other servers', () {
    final server = package('first');
    package('second');
    expect(discoverServer(directory('first/lib/src')).path, server.path);
  });

  test('multiple servers are listed in stable order and require a root', () {
    final second = package('z_server');
    final first = package('a_server');
    final client = package('client', 'serverpod_client: any');
    for (final start in [fixture, client]) {
      expect(
        () => discoverServer(start),
        throwsA(
          isA<ServerDiscoveryException>().having(
            (error) => error.message,
            'message',
            'Multiple Serverpod servers found:\n'
                '  ${first.path}\n  ${second.path}\n'
                'Choose one with --root=/path/to/server.',
          ),
        ),
      );
    }
  });

  test('outside the project does not discover a neighboring server', () {
    package('project/backend');
    final outside = directory('outside');
    File(p.join(outside.path, '.git')).writeAsStringSync('gitdir: elsewhere');
    expect(
      () => discoverServer(outside),
      throwsA(
        isA<ServerDiscoveryException>().having(
          (error) => error.message,
          'message',
          contains('No Serverpod server found'),
        ),
      ),
    );
  });

  test('unmarked unrelated package does not search neighboring projects', () {
    Directory(p.join(fixture.path, '.git')).deleteSync();
    package('serverpod_project/backend');
    package('unrelated', 'collection: any');
    expect(
      () => discoverServer(directory('unrelated/lib')),
      throwsA(isA<ServerDiscoveryException>()),
    );
  });

  test('unmarked outside directory does not search neighboring projects', () {
    Directory(p.join(fixture.path, '.git')).deleteSync();
    package('serverpod_project/backend');
    package('unrelated', 'collection: any');
    expect(
      () => discoverServer(directory('outside')),
      throwsA(isA<ServerDiscoveryException>()),
    );
  });

  test('workspace marker bounds nested package discovery without Git', () {
    Directory(p.join(fixture.path, '.git')).deleteSync();
    File(p.join(fixture.path, 'pubspec.yaml')).writeAsStringSync(
      'name: project\nworkspace:\n  - packages/backend\n  - packages/client\n',
    );
    final server = package('packages/backend');
    package('packages/client', 'serverpod_client: any');
    expect(discoverServer(directory('packages/client/lib')).path, server.path);
  });

  test('sibling packages identify a project without Git or a workspace', () {
    Directory(p.join(fixture.path, '.git')).deleteSync();
    final server = package('backend');
    package('client', 'serverpod_client: any');
    for (final start in [fixture, directory('client/lib'), directory('docs')]) {
      expect(discoverServer(start).path, server.path);
    }
  });

  test('finds nested servers from a project root without markers', () {
    Directory(p.join(fixture.path, '.git')).deleteSync();
    final server = package('packages/backend');
    expect(discoverServer(fixture).path, server.path);
  });

  test(
    'accepts dependency mappings, null values, quotes, and YAML aliases',
    () {
      final server = directory('backend');
      for (final source in [
        'dependencies: {serverpod: {path: ../serverpod}}',
        'dependencies:\n  serverpod:',
        'dependencies:\n  "serverpod": any',
        'shared: &deps {serverpod: any}\ndependencies: *deps',
      ]) {
        File(p.join(server.path, 'pubspec.yaml')).writeAsStringSync(source);
        expect(discoverServer(fixture).path, server.path, reason: source);
      }
    },
  );

  test('dev dependencies, overrides, names, and comments are not servers', () {
    final fake = directory('fake_server');
    for (final source in [
      'name: serverpod',
      '# dependencies:\n#   serverpod: any',
      'dev_dependencies: {serverpod: any}',
      'dependency_overrides: {serverpod: any}',
      'dependencies: {serverpod_client: any}',
      'dependencies: "serverpod"',
    ]) {
      File(p.join(fake.path, 'pubspec.yaml')).writeAsStringSync(source);
      expect(
        () => discoverServer(fixture),
        throwsA(isA<ServerDiscoveryException>()),
      );
    }
  });

  test('does not descend into build/cache directories or symbolic links', () {
    final server = package('backend');
    for (final name in [
      '.git',
      '.dart_tool',
      '.pub-cache',
      '.pub',
      '.fvm',
      'build',
      'node_modules',
    ]) {
      package('$name/fake');
    }
    Link(p.join(fixture.path, 'loop')).createSync(fixture.path);
    Link(p.join(fixture.path, 'alias')).createSync(server.path);
    expect(discoverServer(fixture).path, server.path);
  });

  test('malformed pubspec reports its path', () {
    final server = directory('backend');
    final file = File(p.join(server.path, 'pubspec.yaml'))
      ..writeAsStringSync('dependencies: [');
    expect(
      () => discoverServer(fixture),
      throwsA(
        isA<ServerDiscoveryException>().having(
          (error) => error.message,
          'message',
          contains('Cannot read ${file.path}'),
        ),
      ),
    );
  });

  test('empty projects require an explicit root', () {
    expect(
      () => discoverServer(fixture),
      throwsA(isA<ServerDiscoveryException>()),
    );
  });

  test('explicit absolute and relative roots bypass ambiguous discovery', () {
    final server = package('first');
    package('second');
    for (final root in [server.path, 'first', './first/../first/']) {
      expect(
        resolveScanRoot(currentDirectory: fixture, explicitRoot: root).path,
        server.path,
      );
    }
  });

  test('explicit roots do not require a Serverpod dependency', () {
    final root = directory('sql');
    expect(
      resolveScanRoot(currentDirectory: fixture, explicitRoot: 'sql').path,
      root.path,
    );
  });

  test(
    'positional paths bypass discovery and keep current diagnostic root',
    () {
      expect(
        resolveScanRoot(currentDirectory: fixture, hasPaths: true),
        fixture,
      );
    },
  );

  test('invalid explicit roots fail rather than falling back to discovery', () {
    package('backend');
    File(p.join(fixture.path, 'query.sql')).writeAsStringSync('SELECT 1;');
    for (final root in ['', 'missing', 'query.sql']) {
      expect(
        () => resolveScanRoot(currentDirectory: fixture, explicitRoot: root),
        throwsA(isA<ServerDiscoveryException>()),
      );
    }
  });

  group('CLI', () {
    late Directory bundle;
    late String executable;

    setUpAll(() async {
      bundle = Directory.systemTemp.createTempSync('server_discovery_cli_');
      executable = p.join(bundle.path, 'bundle', 'bin', 'serverpod_sql_check');
      final result = await Process.run(Platform.resolvedExecutable, [
        'build',
        'cli',
        '--target=bin/serverpod_sql_check.dart',
        '--output=${bundle.path}',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    tearDownAll(() => bundle.deleteSync(recursive: true));

    Future<ProcessResult> run(Directory cwd, [List<String> args = const []]) =>
        Process.run(executable, args, workingDirectory: cwd.path);

    importedSqlAndHelperTests(() => fixture, run);
    finiteFlowTests(() => fixture, run);
    staticAssemblyTests(() => fixture, run);
    staticContextTests(() => fixture, run);
    staticDemandTests(() => fixture, run);
    staticGetterTests(() => fixture, run);
    staticStringTests(() => fixture, run);
    staticObjectSafetyTests(() => fixture, run);

    for (final testFolder in ['test', 'integration_test']) {
      test('excludes $testFolder SQL and Dart during discovery', () async {
        final server = package('backend');
        File(p.join(directory('backend/lib').path, 'query.dart'))
            .writeAsStringSync("const sql = 'SELECT 1;';");
        final tests = directory('backend/$testFolder/nested');
        File(p.join(tests.path, 'invalid.sql'))
            .writeAsStringSync('SELECT FROM;');
        File(p.join(tests.path, 'invalid_test.dart'))
            .writeAsStringSync("const sql = 'SELECT FROM;';");

        final result = await run(server);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Scanned 0 SQL files and 1 Dart files.'),
        );
        expect(result.stdout, contains('Checked 1 SQL variants; 0 failed;'));
      });

      test('--include-tests checks $testFolder SQL and Dart', () async {
        final server = package('backend');
        final tests = directory('backend/$testFolder/nested');
        File(p.join(tests.path, 'invalid.sql'))
            .writeAsStringSync('SELECT FROM;');
        File(p.join(tests.path, 'invalid_test.dart'))
            .writeAsStringSync("const sql = 'SELECT FROM;';");

        final result = await run(fixture, [
          '--root=${server.path}',
          '--include-tests',
        ]);
        expect(result.exitCode, 1);
        expect(
          result.stdout,
          contains('Scanned 1 SQL files and 1 Dart files.'),
        );
        expect(result.stdout, contains('Checked 2 SQL variants; 2 failed;'));
        expect(result.stderr, contains('$testFolder/nested/invalid.sql'));
        expect(result.stderr, contains('$testFolder/nested/invalid_test.dart'));
      });

      test(
        'explicit $testFolder paths still require --include-tests',
        () async {
          final server = package('backend');
          final tests = directory('backend/$testFolder');
          File(p.join(tests.path, 'invalid.sql'))
              .writeAsStringSync('SELECT FROM;');
          for (final path in [testFolder, '$testFolder/invalid.sql']) {
            final excluded = await run(server, [path]);
            expect(excluded.exitCode, 0);
            expect(
              excluded.stdout,
              contains('Scanned 0 SQL files and 0 Dart files.'),
            );
            final included = await run(server, ['--include-tests', path]);
            expect(included.exitCode, 1);
            expect(included.stdout, contains('Scanned 1 SQL files'));
          }
        },
      );
    }

    test('test and migration inclusion flags work independently', () async {
      final server = package('backend');
      File(p.join(directory('backend/test/migrations').path, 'query.sql'))
          .writeAsStringSync('SELECT FROM;');
      for (final args in [
        <String>[],
        ['--include-tests'],
        ['--include-migrations'],
      ]) {
        final result = await run(server, args);
        expect(result.exitCode, 0);
        expect(result.stdout, contains('Scanned 0 SQL files'));
      }
      final result = await run(server, [
        '--include-tests',
        '--include-migrations',
      ]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('Scanned 1 SQL files'));
    });

    test('excluding tests preserves production SQL failures', () async {
      final server = package('backend');
      File(p.join(directory('backend/lib').path, 'invalid.sql'))
          .writeAsStringSync('SELECT FROM;');
      File(p.join(directory('backend/test').path, 'valid.sql'))
          .writeAsStringSync('SELECT 1;');
      final result = await run(server);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('Scanned 1 SQL files'));
      expect(result.stderr, contains('FAIL lib/invalid.sql'));
    });

    test('detects from client and scans only the entire server', () async {
      final server = package('backend');
      final client = package('client', 'serverpod_client: any');
      File(p.join(client.path, 'invalid.sql'))
          .writeAsStringSync('SELECT FROM;');
      File(p.join(server.path, 'first.sql')).writeAsStringSync('SELECT 1;');
      final subfolder = directory('backend/lib/nested');
      File(p.join(subfolder.path, 'second.sql')).writeAsStringSync('SELECT 2;');
      for (final cwd in [client, subfolder, fixture]) {
        final result = await run(cwd);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Detected Serverpod server: ${server.path}'),
        );
        expect(result.stdout, contains('Scanned 2 SQL files'));
      }
    });

    test(
      'discovered server receives PL/pgSQL checking and relative diagnostics',
      () async {
        final server = package('backend');
        File(p.join(server.path, 'broken.sql'))
            .writeAsStringSync(r'DO $$ BEGIN IF THEN END IF; END; $$;');
        final result = await run(directory('backend/lib'));
        expect(result.exitCode, 1);
        expect(result.stderr, contains('FAIL broken.sql:1:1'));
        expect(result.stderr, contains('PL/pgSQL:'));
      },
    );

    test(
      'multiple servers fail with paths and explicit root takes priority',
      () async {
        final first = package('first');
        final second = package('second');
        File(p.join(first.path, 'good.sql')).writeAsStringSync('SELECT 1;');
        File(p.join(second.path, 'bad.sql')).writeAsStringSync('SELECT FROM;');
        final ambiguous = await run(fixture);
        expect(ambiguous.exitCode, 2);
        expect(ambiguous.stderr, contains(first.path));
        expect(ambiguous.stderr, contains(second.path));
        expect(ambiguous.stderr, contains('--root=/path/to/server'));
        final explicit = await run(second, ['--root=../first']);
        expect(
          explicit.exitCode,
          0,
          reason: '${explicit.stdout}\n${explicit.stderr}',
        );
        expect(explicit.stdout, isNot(contains('Detected Serverpod server')));
        expect(explicit.stdout, contains('Scanned 1 SQL files'));
      },
    );

    test(
      'outside a project fails but explicit paths and help still work',
      () async {
        File(p.join(fixture.path, 'good.sql')).writeAsStringSync('SELECT 1;');
        final missing = await run(fixture);
        expect(missing.exitCode, 2);
        expect(missing.stderr, contains('No Serverpod server found'));
        final explicit = await run(fixture, ['good.sql']);
        expect(explicit.exitCode, 0);
        expect(explicit.stdout, contains('Scanned 1 SQL files'));
        final help = await run(fixture, ['--help']);
        expect(help.exitCode, 0);
        expect(help.stdout, contains('overrides server discovery'));
        expect(help.stdout, contains('--include-tests'));
      },
    );
  });
}
