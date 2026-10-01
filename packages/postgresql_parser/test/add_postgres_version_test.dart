import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('published releases are listed without uploaded assets', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'pg-releases-test-',
    );
    try {
      final fixture = File('${temporary.path}/releases.json');
      await fixture.writeAsString(
        jsonEncode([
          {
            'tag_name': '18.1.0',
            'draft': false,
            'prerelease': false,
            'assets': [],
          },
          {
            'tag_name': '18.0.0',
            'draft': false,
            'prerelease': false,
            'assets': [],
          },
          {
            'tag_name': '18.2.0-rc1',
            'draft': false,
            'prerelease': true,
            'assets': [],
          },
        ]),
      );
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/add_postgres_version.dart',
        '--list-releases',
        '18',
        '--releases-json',
        fixture.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('18.1.0'));
      expect(result.stdout, contains('18.0.0'));
      expect(result.stdout, isNot(contains('18.2.0-rc1')));
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test('updating an installed version to its current pin is a no-op', () async {
    final upstream = await File('native/pg18/UPSTREAM.md').readAsString();
    final pin = RegExp(r'- Release tag: \[`([^`]+)`\]')
        .firstMatch(upstream)!
        .group(1)!;
    final result = await Process.run(Platform.resolvedExecutable, [
      'tool/add_postgres_version.dart',
      '18',
      '--update',
      '--tag',
      pin,
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('already pinned to $pin'));
  });
}
