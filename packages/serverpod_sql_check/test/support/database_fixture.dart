import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A small real Serverpod project, using the installed framework's migrations
/// and protocol (including its system tables), plus a custom schema hook.
Future<Directory> createDatabaseFixture(
  String version, {
  bool offline = false,
}) async {
  final root = await Directory.systemTemp.createTemp('sql-lifecycle-project-');
  await File('${root.path}/pubspec.yaml').writeAsString('''
name: checker_fixture
environment:
  sdk: ^3.13.4
dependencies:
  serverpod: $version
  postgres: ^3.5.18
''');
  final dependencies = await Process.run(Platform.resolvedExecutable, [
    'pub',
    'get',
    if (offline) '--offline',
  ], workingDirectory: root.path);
  if (dependencies.exitCode != 0) {
    await root.delete(recursive: true);
    throw StateError(
      'Fixture dependency resolution failed: ${dependencies.stderr}',
    );
  }
  final config = File('${root.path}/.dart_tool/package_config.json');
  final packages =
      (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
  final server = Directory.fromUri(
    config.uri.resolve(
      (packages.singleWhere((e) => e['name'] == 'serverpod') as Map)['rootUri']
          as String,
    ),
  ).uri;
  Future<void> copy(Directory source, Directory target) async {
    await target.create(recursive: true);
    for (final entry in source.listSync(followLinks: false)) {
      final path = p.join(target.path, p.basename(entry.path));
      if (entry is Directory) {
        await copy(entry, Directory(path));
      }
      if (entry is File) {
        await entry.copy(path);
      }
    }
  }

  await copy(
    Directory.fromUri(server.resolve('migrations/')),
    Directory('${root.path}/migrations'),
  );
  await Directory('${root.path}/lib/src/generated').create(recursive: true);
  await File('${root.path}/lib/src/generated/protocol.dart').writeAsString('''
import 'package:serverpod/protocol.dart' as framework;
import 'helper_identity.dart';
import 'package:checker_fixture/src/identity_api.dart';

// Like generated application code, combine relative and package imports.
// Importing this library by file URI duplicates HelperIdentity and fails.
framework.Protocol Protocol() {
  acceptHelperIdentity(HelperIdentity());
  return framework.Protocol();
}
''');
  await File('${root.path}/lib/src/generated/helper_identity.dart')
      .writeAsString('class HelperIdentity {}\n');
  await File('${root.path}/lib/src/identity_api.dart').writeAsString('''
import 'package:checker_fixture/src/generated/helper_identity.dart';
void acceptHelperIdentity(HelperIdentity value) {}
''');
  await File('${root.path}/lib/src/generated/endpoints.dart').writeAsString(
    "export 'package:serverpod/src/generated/endpoints.dart' show Endpoints;\n",
  );
  await Directory('${root.path}/config').create();
  for (final mode in ['test', 'development']) {
    await File('${root.path}/config/$mode.yaml').writeAsString('''
database:
  host: localhost
  port: ${mode == 'test' ? 9090 : 8090}
  name: fixture${mode == 'test' ? '_test' : ''}
  user: postgres
  ${version.startsWith('4.') ? 'dataPath: .serverpod/$mode/pgdata' : ''}
''');
  }
  await File('${root.path}/config/passwords.yaml')
      .writeAsString('shared:\n  database: fixture_secret_not_displayed\n');
  await File('${root.path}/docker-compose.yaml').writeAsString('''
services:
  pg_test:
    image: postgres:16
    environment:
      POSTGRES_DB: fixture_test
    ports:
      - "9090:5432"
''');
  await Directory('${root.path}/tool').create();
  await File('${root.path}/tool/setup.dart').writeAsString(r'''
import 'dart:io';
import 'package:postgres/postgres.dart';
Future<void> main(List<String> args) async {
  final connection = await Connection.openFromUrl(Platform.environment['SQL_CHECK_DATABASE_URL']!);
  try {
    if (args.single == '--phase=before-migrations') {
      await connection.execute('CREATE SCHEMA app');
    } else {
      await connection.execute('CREATE TABLE app.products(id int PRIMARY KEY, label text)');
      await connection.execute("INSERT INTO app.products VALUES (1, 'unchanged')");
      await connection.execute('CREATE TABLE app.source(id int PRIMARY KEY, label text)');
    }
  } finally { await connection.close(); }
}
''');
  await File('${root.path}/lib/queries.dart').writeAsString(r'''
Future<void> queries(dynamic session) async {
  await session.db.unsafeQuery('SELECT label FROM app.products WHERE id = @id', parameters: {'id': 1});
  await session.db.unsafeExecute("UPDATE app.products SET label = 'modified' WHERE id = 1");
  await session.db.unsafeExecute('DELETE FROM app.products');
  await session.db.unsafeExecute("INSERT INTO app.products VALUES (2, 'new')");
  await session.db.unsafeExecute('MERGE INTO app.products p USING app.source s ON p.id = s.id WHEN MATCHED THEN DELETE');
  await session.db.unsafeQuery('WITH removed AS (DELETE FROM app.products RETURNING *) SELECT * FROM removed');
}
''');
  return root;
}
