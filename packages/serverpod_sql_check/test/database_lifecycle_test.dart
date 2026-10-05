import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';
import 'package:serverpod_sql_check/src/database_check.dart';
import 'package:serverpod_sql_check/src/database_lease.dart';
import 'package:serverpod_sql_check/src/database_project.dart';
import 'package:test/test.dart';

import 'support/database_fixture.dart';

void main() {
  if (Platform.environment['SQL_CHECK_TEST_LIFECYCLE'] != '1') {
    test(
      'database lifecycle integration is opt-in',
      () {},
      skip: 'Set SQL_CHECK_TEST_LIFECYCLE=1; requires Docker, Dart and embedded binaries.',
    );
    return;
  }
  final backend = Platform.environment['SQL_CHECK_TEST_BACKEND'] ?? 'docker';
  final version = Platform.environment['SQL_CHECK_TEST_SERVERPOD'] ?? '4.0.2';
  final image =
      Platform.environment['SQL_CHECK_TEST_DOCKER_IMAGE'] ?? 'postgres:16';
  final major = int.parse(Platform.environment['SQL_CHECK_TEST_MAJOR'] ?? '16');
  late Directory fixture;
  late String executable;
  setUpAll(() async {
    fixture = await createDatabaseFixture(
      version,
      offline: Platform.environment['SQL_CHECK_TEST_OFFLINE'] == '1',
    );
    final output = '${fixture.path}/.dart_tool/checker_bundle';
    final build = await Process.run(Platform.resolvedExecutable, [
      'build',
      'cli',
      '--target=bin/serverpod_sql_check.dart',
      '--output=$output',
    ]);
    if (build.exitCode != 0) {
      throw StateError('CLI build failed: ${build.stderr}');
    }
    executable = '$output/bundle/bin/serverpod_sql_check';
  });
  tearDownAll(() => fixture.delete(recursive: true));
  final leases = <DatabaseLease>[];
  tearDown(() async {
    for (final lease in leases) {
      await lease.close();
    }
    leases.clear();
  });
  Future<DatabaseLease> open({String? setup = 'tool/setup.dart'}) async {
    final lease = DatabaseLease();
    leases.add(lease);
    await lease.open(
      DatabaseOptions(
        target: 'temporary',
        backend: backend,
        image: backend == 'docker' ? image : null,
        setup: setup,
      ),
      fixture,
      {},
    );
    return lease;
  }

  Future<ProcessResult> runCli({List<String> extra = const []}) => Process.run(
    executable,
    [
      '--root=${fixture.path}',
      '--database-check',
      if (backend == 'docker') '--database-docker-image=$image',
      ...extra,
    ],
    environment: {
      ...Platform.environment,
      'SQL_CHECK_DATABASE_URL': '',
      'PATH':
          '${p.dirname(Platform.resolvedExecutable)}:${Platform.environment['PATH']}',
    },
  );

  if (backend == 'docker') {
    test('local-only image override needs no registry pull', () async {
      final alias =
          'sql-check-local-fixture-$pid-${DateTime.now().microsecondsSinceEpoch}:test';
      final available = await Process.run('docker', [
        'image',
        'inspect',
        image,
      ]);
      if (available.exitCode != 0) {
        final pull = await Process.run('docker', ['pull', image]);
        expect(
          pull.exitCode,
          0,
          reason: 'Could not obtain the fixture base image.',
        );
      }
      final tag = await Process.run('docker', ['tag', image, alias]);
      expect(tag.exitCode, 0, reason: 'Could not tag the fixture image.');
      final lease = DatabaseLease();
      leases.add(lease);
      try {
        await lease.open(
          DatabaseOptions(backend: 'docker', image: alias),
          fixture,
          {},
        );
        final connection = await Connection.openFromUrl(lease.url);
        try {
          expect((await connection.execute('SELECT 1')).single, [1]);
        } finally {
          await connection.close();
        }
      } finally {
        await lease.close();
        final removal = await Process.run('docker', ['image', 'rm', alias]);
        expect(
          removal.exitCode,
          0,
          reason: 'Could not remove the fixture image tag.',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 8)));
  }

  test(
    'CLI defaults to a temporary instance and keeps offline coverage',
    () async {
      final connected = await runCli(
        extra: ['--database-setup=tool/setup.dart'],
      );
      expect(
        connected.exitCode,
        0,
        reason: '${connected.stdout}${connected.stderr}',
      );
      expect(
        connected.stdout,
        contains('Database target: temporary; backend: $backend'),
      );
      expect(
        connected.stdout,
        contains('Checked 6 database statements; 0 failed'),
      );
      expect(connected.stdout, contains('schema preparation:'));
      final offline = await Process.run(executable, ['--root=${fixture.path}']);
      expect(offline.exitCode, 0, reason: '${offline.stderr}');
      final count = RegExp(r'Checked (\d+) SQL variants');
      expect(
        count.firstMatch('${connected.stdout}')!.group(1),
        count.firstMatch('${offline.stdout}')!.group(1),
      );
      expect(
        '${connected.stdout}${connected.stderr}',
        isNot(contains('fixture_secret_not_displayed')),
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test('SIGINT during preparation cleans up and returns an operational error', () async {
    final script = File('${fixture.path}/tool/wait.dart');
    final marker = File('${fixture.path}/preparation_started');
    await script.writeAsString(
      "import 'dart:io';\nFuture<void> main() async { File('preparation_started').writeAsStringSync('ready'); await Future<void>.delayed(const Duration(minutes: 3)); }\n",
    );
    final process = await Process.start(
      executable,
      [
        '--root=${fixture.path}',
        '--database-check',
        if (backend == 'docker') '--database-docker-image=$image',
        '--database-setup=tool/wait.dart',
      ],
      environment: {
        ...Platform.environment,
        'SQL_CHECK_DATABASE_URL': '',
        'PATH':
            '${p.dirname(Platform.resolvedExecutable)}:${Platform.environment['PATH']}',
      },
    );
    final stdoutResult = process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final stderrResult = process.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    final watch = Stopwatch()..start();
    while (!marker.existsSync() &&
        watch.elapsed < const Duration(seconds: 90)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!marker.existsSync()) {
      process.kill();
      fail('Preparation did not become ready: ${await stderrResult}');
    }
    process.kill(ProcessSignal.sigint);
    expect(await process.exitCode.timeout(const Duration(seconds: 40)), 2);
    expect(await stderrResult, contains('cleaning up owned resources'));
    await stdoutResult;
    expect(
      Directory('${fixture.path}/.dart_tool/serverpod_sql_check').listSync(),
      isEmpty,
    );
    await marker.delete();
    await script.delete();
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('migrations, modules and phased hook; PREPARE leaves data unchanged', () async {
    final lease = await open();
    await lease.prepare('tool/setup.dart');
    stdout.writeln(
      'Lifecycle timing: $backend startup=${lease.startup.inMilliseconds}ms preparation=${lease.preparation.inMilliseconds}ms',
    );
    final checker = await DatabaseChecker.open(lease.url);
    try {
      expect(checker.major, major);
      for (final sql in [
        'SELECT label FROM app.products',
        "UPDATE app.products SET label = 'modified'",
        'DELETE FROM app.products',
        "INSERT INTO app.products VALUES (2, 'new')",
        'MERGE INTO app.products p USING app.source s ON p.id = s.id WHEN MATCHED THEN DELETE',
        'WITH removed AS (DELETE FROM app.products RETURNING *) SELECT * FROM removed',
      ]) {
        expect(
          (await checker.check(DatabaseStatement(sql, 0, sql.length, null)))
              .status,
          DatabaseCheckStatus.checked,
        );
      }
      expect(
        (await checker.check(
          DatabaseStatement('SELECT missing FROM app.products', 0, 32, null),
        )).status,
        DatabaseCheckStatus.failed,
      );
      expect(
        (await checker.check(
          DatabaseStatement('SELECT * FROM app.absent', 0, 23, null),
        )).status,
        DatabaseCheckStatus.failed,
      );
      expect(
        (await checker.check(
          DatabaseStatement('SELECT label + 1 FROM app.products', 0, 34, null),
        )).status,
        DatabaseCheckStatus.failed,
      );
    } finally {
      await checker.close();
    }
    final connection = await Connection.openFromUrl(lease.url);
    try {
      expect(
        (await connection.execute('SELECT id, label FROM app.products')).single,
        [1, 'unchanged'],
      );
      expect(
        (await connection.execute('SELECT count(*) FROM serverpod_migrations'))
            .single[0],
        greaterThan(0),
      );
    } finally {
      await connection.close();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test(
    'existing instance is attached without migration, data changes or shutdown',
    () async {
      final owner = await open();
      await owner.prepare('tool/setup.dart');
      final endpoint = owner.endpoint!;
      final existing = DatabaseLease();
      leases.add(existing);
      final dataPath = endpoint.isUnixSocket
          ? p.normalize(p.join(p.dirname(endpoint.host), '../pgdata'))
          : null;
      File('${fixture.path}/config/development.yaml').writeAsStringSync('''
database:
  host: ${endpoint.host}
  port: ${endpoint.port}
  name: ${endpoint.database}
  user: ${endpoint.username}
  ${dataPath == null ? '' : 'dataPath: $dataPath'}
''');
      await existing.open(DatabaseOptions(target: 'existing'), fixture, {
        'SERVERPOD_DATABASE_PASSWORD': endpoint.password ?? '',
      });
      final checker = await DatabaseChecker.open(existing.url);
      await checker.close();
      await existing.close();
      final connection = await Connection.openFromUrl(owner.url);
      try {
        expect(
          (await connection.execute('SELECT label FROM app.products')).single,
          ['unchanged'],
        );
      } finally {
        await connection.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'hook failure redacts connection credentials and cleanup is repeatable',
    () async {
      final lease = await open(setup: null);
      File('${fixture.path}/tool/fail.dart').writeAsStringSync(r'''
import 'dart:io';
void main() { stderr.writeln(Platform.environment['SQL_CHECK_DATABASE_URL']); exitCode = 1; }
''');
      await expectLater(
        lease.prepare('tool/fail.dart'),
        throwsA(
          isA<DatabaseCheckException>().having(
            (e) => e.message,
            'credentials',
            isNot(contains(lease.endpoint!.password!)),
          ),
        ),
      );
      await lease.close();
      await lease.close();
      expect(() async => Connection.openFromUrl(lease.url), throwsA(anything));
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test('concurrent instances are isolated and independently cleaned', () async {
    final pair = await Future.wait([open(setup: null), open(setup: null)]);
    expect(pair[0].endpoint!.database, isNot(pair[1].endpoint!.database));
    await pair[0].close();
    final connection = await Connection.openFromUrl(pair[1].url);
    try {
      expect((await connection.execute('SELECT 1')).single, [1]);
    } finally {
      await connection.close();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test(
    'migration failure stops preparation and releases the instance',
    () async {
      final lease = await open(setup: null);
      final versions =
          Directory('${fixture.path}/migrations')
              .listSync()
              .whereType<Directory>()
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      final definition = File('${versions.last.path}/definition.sql');
      final original = await definition.readAsString();
      try {
        await definition.writeAsString('CREATE TABLE ;\n');
        await expectLater(
          lease.prepare(null),
          throwsA(
            isA<DatabaseCheckException>().having(
              (error) => error.message,
              'stage',
              contains('migration preparation failed'),
            ),
          ),
        );
      } finally {
        await definition.writeAsString(original);
        await lease.close();
      }
      expect(() async => Connection.openFromUrl(lease.url), throwsA(anything));
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
