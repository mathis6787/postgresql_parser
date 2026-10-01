import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/add_postgres_version.dart'
    show applyPlpgsqlCompatibilityFix, installStagedVersion;
import '../tool/ffigen.dart' show generateBindings;

Future<File> _write(Directory root, String path, String content) async {
  final file = File('${root.path}/$path');
  await file.parent.create(recursive: true);
  return file.writeAsString(content);
}

Future<Directory> _fixture(Directory temporary) async {
  final root = await Directory('${temporary.path}/package').create();
  for (final path in [
    'lib/src/backends/pg17.dart',
    'lib/src/postgres_version.dart',
    'lib/src/postgres_parser.dart',
    'tool/ffigen.dart',
  ]) {
    await _write(root, path, await File(path).readAsString());
  }
  await _write(root, 'native/versions.json', '[17]\n');
  await Directory('${root.path}/lib/src/native').create();
  return root;
}

Future<Directory> _stage(Directory temporary, {bool invalid = false}) async {
  final stage = await Directory('${temporary.path}/staged').create();
  final header = await File('native/pg17/bridge.h').readAsString();
  await _write(
    stage,
    'bridge.h',
    invalid ? 'this is not a C header;' : header.replaceAll('17', '19'),
  );
  return stage;
}

void main() {
  test(
    'generates a staged version from its header and installs its registry',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'pg-install-test-',
      );
      try {
        final root = await _fixture(temporary);
        final stage = await _stage(temporary);
        await installStagedVersion(
          staged: stage,
          packageRoot: root.path,
          major: 19,
        );
        final bindings = File('${root.path}/lib/src/native/pg19.dart');
        final content = await bindings.readAsString();
        expect(content, contains('pgp19_parse_plpgsql'));
        expect(content, contains('Pg19ParseResponse extends ffi.Struct'));
        expect(content, contains('@ffi.Int()'));
        expect(
          content,
          contains('package:postgresql_parser/src/native/pg19.dart'),
        );
        expect(content, isNot(contains('pgp17')));
        expect(
          jsonDecode(
            await File('${root.path}/native/versions.json').readAsString(),
          ),
          [17, 19],
        );
        expect(
          await File('${root.path}/lib/src/postgres_parser.dart')
              .readAsString(),
          contains('19: Pg19Backend()'),
        );
        expect(
          await File('${root.path}/lib/src/backends/pg19.dart').readAsString(),
          contains('pgp19_parse_plpgsql'),
        );

        // Check mode must detect drift and leave the committed file untouched.
        final packages = File('../../.dart_tool/package_config.json').absolute;
        Future<ProcessResult> check() =>
            Process.run(Platform.resolvedExecutable, [
              '--packages=${packages.path}',
              '${root.path}/tool/ffigen.dart',
              '--check',
            ]);
        await _write(root, 'native/versions.json', '[19]\n');
        final fresh = await check();
        expect(fresh.exitCode, 0, reason: '${fresh.stdout}${fresh.stderr}');
        final stale = '$content\n// stale fixture\n';
        await bindings.writeAsString(stale);
        final drift = await check();
        expect(drift.exitCode, 1, reason: '${drift.stdout}${drift.stderr}');
        expect(drift.stderr, contains('PostgreSQL 19 are stale'));
        expect(await bindings.readAsString(), stale);
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );

  test(
    'generation failure restores files and removes partial installation',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'pg-rollback-test-',
      );
      try {
        final root = await _fixture(temporary);
        final stage = await _stage(temporary, invalid: true);
        final original = <String, String>{};
        for (final path in [
          'native/versions.json',
          'lib/src/postgres_version.dart',
          'lib/src/postgres_parser.dart',
        ]) {
          original[path] = await File('${root.path}/$path').readAsString();
        }
        await expectLater(
          installStagedVersion(
            staged: stage,
            packageRoot: root.path,
            major: 19,
          ),
          throwsA(anything),
        );
        for (final entry in original.entries) {
          expect(
            await File('${root.path}/${entry.key}').readAsString(),
            entry.value,
          );
        }
        expect(Directory('${root.path}/native/pg19').existsSync(), isFalse);
        expect(
          File('${root.path}/lib/src/backends/pg19.dart').existsSync(),
          isFalse,
        );
        expect(
          File('${root.path}/lib/src/native/pg19.dart').existsSync(),
          isFalse,
        );
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );

  test('includes only bridge functions and the response struct', () async {
    final temporary = await Directory.systemTemp.createTemp('pg-filter-test-');
    try {
      final header = await _write(temporary, 'bridge.h', '''
typedef struct Pg19ParseResponse {
  char *tree_json;
  char *error_message;
  int cursor_position;
} Pg19ParseResponse;
Pg19ParseResponse *pgp19_parse(const char *sql);
Pg19ParseResponse *pgp19_parse_plpgsql(const char *sql);
void pgp19_free_response(Pg19ParseResponse *response);
void unrelated_function(void);
typedef struct OtherStruct { int ignored; } OtherStruct;
''');
      final output = File('${temporary.path}/pg19.dart');
      await generateBindings(major: 19, header: header.uri, output: output.uri);
      final content = await output.readAsString();
      expect(content, contains('pgp19_parse_plpgsql'));
      expect(content, isNot(contains('unrelated_function')));
      expect(content, isNot(contains('OtherStruct')));
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test('trigger serializer compatibility fix is idempotent', () async {
    final temporary = await Directory.systemTemp.createTemp('pg-patch-test-');
    try {
      final fixed = await File(
        'native/pg18/libpg_query/src/pg_query_json_plpgsql.c',
      ).readAsString();
      final original = fixed.replaceAll(
        RegExp(r'^[\t ]*case PLPGSQL_DTYPE_PROMISE:\n', multiLine: true),
        '',
      );
      final file = await _write(
        temporary,
        'src/pg_query_json_plpgsql.c',
        original,
      );
      expect(await applyPlpgsqlCompatibilityFix(temporary), isTrue);
      expect(await file.readAsString(), fixed);
      expect(await applyPlpgsqlCompatibilityFix(temporary), isFalse);
      // An upstream fix may place the promise case before the variable case.
      final reversed = fixed.replaceAllMapped(
        RegExp(
          r'^([\t ]*)case PLPGSQL_DTYPE_VAR:\n'
          r'[\t ]*case PLPGSQL_DTYPE_PROMISE:\n',
          multiLine: true,
        ),
        (match) =>
            '${match[1]}case PLPGSQL_DTYPE_PROMISE:\n'
            '${match[1]}case PLPGSQL_DTYPE_VAR:\n',
      );
      await file.writeAsString(reversed);
      expect(await applyPlpgsqlCompatibilityFix(temporary), isFalse);
      expect(await file.readAsString(), reversed);
    } finally {
      await temporary.delete(recursive: true);
    }
  });
}
