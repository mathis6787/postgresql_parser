import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:serverpod_sql_check/src/database_check.dart';
import 'package:serverpod_sql_check/src/database_helpers.dart';
import 'package:serverpod_sql_check/src/database_lease.dart';
import 'package:serverpod_sql_check/src/database_project.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('sql-project-');
    File('${root.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\ndependencies:\n  serverpod: any\n');
    Directory('${root.path}/config').createSync();
    File('${root.path}/config/test.yaml').writeAsStringSync('''
database:
  host: localhost
  port: 9090
  name: fixture_test
  user: postgres
  dataPath: .serverpod/test/pgdata
  searchPaths: custom,public
''');
    File('${root.path}/config/passwords.yaml').writeAsStringSync(
      'shared:\n  database: shared_secret\ntest:\n  database: mode_secret\n',
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('temporary default and explicit URL compatibility', () {
    expect(DatabaseOptions().resolveTarget({}), 'temporary');
    expect(
      DatabaseOptions().resolveTarget({
        'SQL_CHECK_DATABASE_URL': 'postgresql:test',
      }),
      'existing',
    );
    expect(
      DatabaseOptions(mode: 'test')
          .resolveTarget({'SQL_CHECK_DATABASE_URL': 'postgresql:test'}),
      'existing',
    );
    expect(
      () =>
          DatabaseOptions(target: 'temporary')
              .resolveTarget({'SQL_CHECK_DATABASE_URL': 'secret'}),
      throwsA(isA<DatabaseCheckException>()),
    );
    expect(
      () => DatabaseOptions(explicitUrlEnv: true).resolveTarget({}),
      throwsA(isA<DatabaseCheckException>()),
    );
  });
  test('rejects invalid and conflicting options', () {
    for (final options in [
      DatabaseOptions(target: 'invalid'),
      DatabaseOptions(mode: 'production'),
      DatabaseOptions(backend: 'bad'),
      DatabaseOptions(target: 'existing', setup: 'hook.dart'),
      DatabaseOptions(backend: 'embedded', image: 'postgres:16'),
      DatabaseOptions(image: ''),
    ]) {
      expect(
        () => options.resolveTarget({}),
        throwsA(isA<DatabaseCheckException>()),
      );
    }
  });
  test('loads selected mode, password and relative dataPath', () {
    final project = DatabaseProject.load(root, 'test', {});
    expect(project.endpoint.password, 'mode_secret');
    expect(project.endpoint.port, 9090);
    expect(project.searchPath, 'custom,public');
    expect(project.postgresSearchPath, '"custom", "public"');
    expect(project.dataPath, endsWith('/.serverpod/test/pgdata'));
    expect(
      () => DatabaseProject.load(root, 'development', {}),
      throwsA(isA<DatabaseCheckException>()),
    );
  });
  test(
    'project schema names preserve case and helper paths preserve quoting',
    () async {
      final project = DatabaseProject.load(root, 'test', {
        'SERVERPOD_DATABASE_SEARCH_PATHS': 'MixedCase, schema with spaces',
      });
      expect(project.postgresSearchPath, '"MixedCase", "schema with spaces"');
      final helper = migrationHelper(protocol: '', endpoints: '');
      final method = helper.substring(
        helper.indexOf('List<String>? searchPaths'),
      );
      final script = File('${root.path}/search_path.dart');
      await script.writeAsString('''
import 'dart:convert';
$method
void main() { print(jsonEncode(searchPaths(r'PUBLIC, "MixedCase", " space ", "comma,name", "a""b", 雪'))); }
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        script.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(jsonDecode('${result.stdout}'), [
        'public',
        'MixedCase',
        ' space ',
        'comma,name',
        'a"b',
        '雪',
      ]);
    },
  );
  test(
    'environment takes priority, including shared/custom password rules',
    () {
      final project = DatabaseProject.load(root, 'test', {
        'SERVERPOD_DATABASE_HOST': 'other',
        'SERVERPOD_DATABASE_PORT': '55432',
        'SERVERPOD_DATABASE_NAME': 'other_db',
        'SERVERPOD_DATABASE_USER': 'other_role',
        'SERVERPOD_DATABASE_PASSWORD': 'first',
        'SERVERPOD_PASSWORD_database': 'last',
        'SERVERPOD_DATABASE_DATA_PATH': '',
        'SERVERPOD_DATABASE_REQUIRE_SSL': 'true',
        'SERVERPOD_DATABASE_SEARCH_PATHS': 'other_schema',
      });
      expect(project.endpoint.host, 'other');
      expect(project.endpoint.password, 'last');
      expect(project.endpoint.port, 55432);
      expect(project.dataPath, isNull);
      expect(project.requireSsl, isTrue);
      expect(project.searchPath, 'other_schema');
      File('${root.path}/config/passwords.yaml')
          .writeAsStringSync('shared:\n  database: shared_secret\n');
      expect(
        DatabaseProject.load(root, 'test', {}).endpoint.password,
        'shared_secret',
      );
    },
  );
  test('malformed YAML never echoes secrets', () {
    File('${root.path}/config/passwords.yaml')
        .writeAsStringSync('test: [private_password');
    expect(
      () => DatabaseProject.load(root, 'test', {}),
      throwsA(
        isA<DatabaseCheckException>().having(
          (e) => e.message,
          'message',
          isNot(contains('private_password')),
        ),
      ),
    );
  });
  test('preflight gives a dependency instruction before startup', () {
    final project = DatabaseProject.load(root, 'test', {});
    expect(
      () => project.preflight(migrations: true, embedded: true),
      throwsA(
        isA<DatabaseCheckException>().having(
          (e) => e.message,
          'message',
          contains('dart pub get'),
        ),
      ),
    );
  });
  test(
    'preflight uses resolved dependency roots and requires generated files',
    () {
      final dependency = Directory('${root.path}/resolved_serverpod')
        ..createSync();
      File('${dependency.path}/pubspec.yaml')
          .writeAsStringSync('version: 4.0.2\n');
      Directory('${root.path}/.dart_tool').createSync();
      File('${root.path}/.dart_tool/package_config.json').writeAsStringSync(
        jsonEncode({
          'packages': [
            {'name': 'fixture', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'serverpod', 'rootUri': '../resolved_serverpod'},
            {
              'name': 'serverpod_embedded_postgres',
              'rootUri': '../resolved_serverpod',
            },
          ],
        }),
      );
      final project = DatabaseProject.load(root, 'test', {});
      expect(
        () => project.preflight(migrations: true, embedded: true),
        throwsA(
          isA<DatabaseCheckException>().having(
            (e) => e.message,
            'instruction',
            contains('serverpod generate'),
          ),
        ),
      );
      Directory('${root.path}/lib/src/generated').createSync(recursive: true);
      for (final name in ['protocol.dart', 'endpoints.dart']) {
        File('${root.path}/lib/src/generated/$name').writeAsStringSync('');
      }
      expect(
        () => project.preflight(migrations: true, embedded: true),
        throwsA(
          isA<DatabaseCheckException>().having(
            (e) => e.message,
            'instruction',
            contains('Create a migration'),
          ),
        ),
      );
      Directory('${root.path}/migrations').createSync();
      File('${root.path}/migrations/migration_registry.txt')
          .writeAsStringSync('');
      project.preflight(migrations: true, embedded: true);
      expect(
        project.generatedImport('protocol.dart'),
        'package:fixture/src/generated/protocol.dart',
      );
      expect(
        project.generatedImport('endpoints.dart'),
        'package:fixture/src/generated/endpoints.dart',
      );
      File('${dependency.path}/pubspec.yaml')
          .writeAsStringSync('version: 3.3.0\n');
      expect(
        () => project.preflight(migrations: false, embedded: true),
        throwsA(
          isA<DatabaseCheckException>().having(
            (e) => e.message,
            'instruction',
            contains('explicit URL'),
          ),
        ),
      );
    },
  );
  test('relative Unix sockets are based on the server root', () {
    final project = DatabaseProject.load(root, 'test', {
      'SERVERPOD_DATABASE_IS_UNIX_SOCKET': 'true',
      'SERVERPOD_DATABASE_HOST': '.serverpod/sockets/.s.PGSQL.5432',
    });
    expect(project.endpoint.isUnixSocket, isTrue);
    expect(
      project.endpoint.host,
      '${root.resolveSymbolicLinksSync()}/.serverpod/sockets/.s.PGSQL.5432',
    );
  });
  test(
    'rejects invalid environment values without exposing their contents',
    () {
      for (final environment in [
        {'SERVERPOD_DATABASE_PORT': 'private_password'},
        {'SERVERPOD_DATABASE_REQUIRE_SSL': 'private_password'},
        {'SERVERPOD_DATABASE_DIALECT': 'private_password'},
        {'SERVERPOD_DATABASE_DATA_PATH': 'private_password\u0000'},
        {'SERVERPOD_DATABASE_SEARCH_PATHS': 'private_password\u0000'},
      ]) {
        expect(
          () => DatabaseProject.load(root, 'test', environment),
          throwsA(
            isA<DatabaseCheckException>().having(
              (e) => e.message,
              'contents',
              isNot(contains('private_password')),
            ),
          ),
        );
      }
    },
  );
  test('redacts credentials and encoded credentials from helper errors', () {
    final lease = DatabaseLease();
    expect(
      lease.redact(
        'Failed postgresql://user:secret@host/db and postgres://other:pw@host/db',
      ),
      isNot(anyOf(contains('secret'), contains('user:'), contains('other:pw'))),
    );
  });
  test('Compose picks the test service by database or published port', () {
    final project = DatabaseProject.load(root, 'test', {});
    Map service(String name, String image, String port) => {
      'image': image,
      'environment': {'POSTGRES_DB': name},
      'ports': [
        {'target': 5432, 'published': port},
      ],
    };
    final compose = {
      'services': {
        'postgres': service('fixture', 'postgres:17', '8090'),
        'postgres_test': service('fixture_test', 'postgres:16', '9090'),
        'redis': {'image': 'redis:7'},
      },
    };
    expect(selectDockerImage(compose, project), 'postgres:16');
    expect(
      () => selectDockerImage({
        'services': {
          'a': service('fixture_test', 'a', '1'),
          'b': service('other', 'b', '9090'),
        },
      }, project),
      throwsA(isA<DatabaseCheckException>()),
    );
    expect(
      () => selectDockerImage({'services': {}}, project),
      throwsA(isA<DatabaseCheckException>()),
    );
    expect(
      () => selectDockerImage({
        'services': {
          'postgres_test': {
            'build': {
              'context': '.',
              'dockerfile': 'docker/postgres/Dockerfile',
            },
            'environment': {'POSTGRES_DB': 'fixture_test'},
          },
        },
      }, project),
      throwsA(
        isA<DatabaseCheckException>().having(
          (error) => error.message,
          'instruction',
          contains('--database-docker-image'),
        ),
      ),
    );
  });
  test('endpoint URLs preserve Unix paths and special credentials', () {
    final endpoint = Endpoint(
      host: '/tmp/socket/.s.PGSQL.5432',
      isUnixSocket: true,
      database: 'fixture',
      username: 'a:b',
      password: 'p@ss:雪',
    );
    final parsed = Uri.parse(endpointUrl(endpoint));
    expect(parsed.host, isEmpty);
    expect(parsed.queryParameters['host'], endpoint.host);
    expect(parsed.queryParameters['password'], endpoint.password);
  });
  test('package imports avoid duplicate identities in generated libraries', () async {
    final generated = Directory('${root.path}/lib/src/generated')
      ..createSync(recursive: true);
    File('${generated.path}/value.dart').writeAsStringSync('class Value {}\n');
    File('${root.path}/lib/consumer.dart').writeAsStringSync('''
import 'package:fixture/src/generated/value.dart';
void acceptValue(Value value) {}
''');
    final protocol = File('${generated.path}/protocol.dart')
      ..writeAsStringSync('''
import 'value.dart';
import 'package:fixture/consumer.dart';
void checkIdentity() { acceptValue(Value()); }
''');
    Directory('${root.path}/.dart_tool').createSync();
    final config = File('${root.path}/.dart_tool/package_config.json')
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'fixture', 'rootUri': '../', 'packageUri': 'lib/'},
          ],
        }),
      );
    final main = File('${root.path}/.dart_tool/main.dart');
    Future<ProcessResult> compile(String uri) async {
      await main.writeAsString(
        "import '$uri' as generated;\nvoid main() { generated.checkIdentity(); }\n",
      );
      return Process.run(Platform.resolvedExecutable, [
        '--packages=${config.path}',
        main.path,
      ]);
    }

    final broken = await compile(protocol.uri.toString());
    expect(broken.exitCode, isNot(0));
    expect('${broken.stderr}', contains("can't be assigned"));
    final corrected = await compile(
      'package:fixture/src/generated/protocol.dart',
    );
    expect(corrected.exitCode, 0, reason: '${corrected.stderr}');
  });
}
