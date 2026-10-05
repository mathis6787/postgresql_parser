import 'dart:convert';
import 'dart:io';

import 'ffigen.dart' show generateBindings;

const _upstream = 'https://github.com/pganalyze/libpg_query.git';
const _releasesApi =
    'https://api.github.com/repos/pganalyze/libpg_query/releases';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage:\n'
      '  dart run tool/add_postgres_version.dart --available\n'
      '  dart run tool/add_postgres_version.dart --list-tags <major>\n'
      '  dart run tool/add_postgres_version.dart --list-releases <major>\n'
      '  dart run tool/add_postgres_version.dart <major> '
      '[--update] (--tag <libpg_query-tag> | --latest) '
      '[--expected-commit <40-character-sha>] '
      '[--expected-sha256 <64-character-sha>] '
      '[--archive <release-tar.gz>] '
      '[--releases-json <file>] '
      '[--repository <git-url-or-path>]\n'
      '--list-tags accepts --repository; release listing accepts --releases-json.',
    );
    return;
  }

  try {
    if (args.isNotEmpty && args.first == '--available') {
      await _showAvailable(_releasesJsonOption(args.skip(1).toList()));
    } else if (args.isNotEmpty && args.first == '--list-tags') {
      if (args.length < 2) {
        throw const FormatException('--list-tags requires a major version.');
      }
      final major = _parseMajor(args[1]);
      await _listTags(major, _repositoryOption(args.skip(2).toList()));
    } else if (args.isNotEmpty && args.first == '--list-releases') {
      if (args.length < 2) {
        throw const FormatException(
          '--list-releases requires a major version.',
        );
      }
      await _listReleases(
        _parseMajor(args[1]),
        _releasesJsonOption(args.skip(2).toList()),
      );
    } else {
      await _changeVersion(args);
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on ProcessException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } on IOException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

int _parseMajor(String value) {
  final major = int.tryParse(value);
  if (major == null || major < 16) {
    throw const FormatException('Major version must be an integer >= 16.');
  }
  return major;
}

String _repositoryOption(List<String> args) {
  if (args.isEmpty) return _upstream;
  if (args.length == 2 && args[0] == '--repository' && args[1].isNotEmpty) {
    return args[1];
  }
  throw const FormatException('Expected only --repository <git-url-or-path>.');
}

String? _releasesJsonOption(List<String> args) {
  if (args.isEmpty) return null;
  if (args.length == 2 && args[0] == '--releases-json' && args[1].isNotEmpty) {
    return args[1];
  }
  throw const FormatException('Expected only --releases-json <file>.');
}

Future<List<String>> _fetchTags(String repository) async {
  final result = await _run('git', [
    'ls-remote',
    '--refs',
    '--tags',
    repository,
  ]);
  final stableTag = RegExp(r'^\d+[-.]\d+(?:\.\d+)+$');
  final tags = <String>{};
  for (final line in const LineSplitter().convert(result)) {
    final ref = line.split('\t').last;
    const prefix = 'refs/tags/';
    if (!ref.startsWith(prefix)) continue;
    final tag = ref.substring(prefix.length);
    if (stableTag.hasMatch(tag)) tags.add(tag);
  }
  return tags.toList()..sort((a, b) => _compareTags(b, a));
}

Future<List<String>> _fetchReleases(String? jsonFile) async {
  final entries = <dynamic>[];
  if (jsonFile != null) {
    entries.addAll(jsonDecode(await File(jsonFile).readAsString()) as List);
  } else {
    final client = HttpClient();
    try {
      for (var page = 1; page <= 20; page++) {
        final request = await client.getUrl(
          Uri.parse('$_releasesApi?per_page=100&page=$page'),
        );
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'postgresql_parser version generator',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw FormatException(
            'GitHub releases API returned HTTP ${response.statusCode}.',
          );
        }
        final batch =
            jsonDecode(await response.transform(utf8.decoder).join()) as List;
        entries.addAll(batch);
        if (batch.length < 100) break;
      }
    } finally {
      client.close(force: true);
    }
  }

  final stableTag = RegExp(r'^\d+[-.]\d+(?:\.\d+)+$');
  final releases = <String>{};
  for (final entry in entries) {
    if (entry is! Map ||
        entry['draft'] == true ||
        entry['prerelease'] == true) {
      continue;
    }
    final tag = entry['tag_name'];
    if (tag is! String || !stableTag.hasMatch(tag)) continue;
    releases.add(tag);
  }
  return releases.toList()..sort((a, b) => _compareTags(b, a));
}

int _compareTags(String a, String b) {
  final aParts = a.split(RegExp(r'[-.]')).map(int.parse).toList();
  final bParts = b.split(RegExp(r'[-.]')).map(int.parse).toList();
  for (var i = 0; i < aParts.length || i < bParts.length; i++) {
    final left = i < aParts.length ? aParts[i] : 0;
    final right = i < bParts.length ? bParts[i] : 0;
    if (left != right) return left.compareTo(right);
  }
  return a.compareTo(b);
}

List<String> _tagsForMajor(List<String> tags, int major) => tags
    .where((tag) => tag.startsWith('$major-') || tag.startsWith('$major.'))
    .toList();

Future<void> _listTags(int major, String repository) async {
  final tags = _tagsForMajor(await _fetchTags(repository), major);
  if (tags.isEmpty) {
    stdout.writeln('No stable libpg_query release tags for PostgreSQL $major.');
    return;
  }
  stdout.writeln('Stable libpg_query tags for PostgreSQL $major:');
  for (final tag in tags) {
    stdout.writeln('  $tag');
  }
}

Future<void> _listReleases(int major, String? jsonFile) async {
  final releases = _tagsForMajor(await _fetchReleases(jsonFile), major);
  if (releases.isEmpty) {
    stdout.writeln('No published libpg_query releases for PostgreSQL $major.');
    return;
  }
  stdout.writeln('Published libpg_query releases for PostgreSQL $major:');
  for (final tag in releases) {
    stdout.writeln('  $tag');
  }
}

Future<void> _showAvailable(String? jsonFile) async {
  final tags = await _fetchReleases(jsonFile);
  final packageRoot = Platform.script.resolve('../').toFilePath();
  final versionsFile = File('$packageRoot/native/versions.json');
  final installed = (jsonDecode(await versionsFile.readAsString()) as List)
      .cast<int>()
      .toSet();
  final majors = <int>{};
  for (final tag in tags) {
    final major = int.parse(tag.split(RegExp(r'[-.]')).first);
    if (major >= 16) majors.add(major);
  }
  if (majors.isEmpty) {
    stdout.writeln('No published libpg_query releases for PostgreSQL 16+.');
    return;
  }
  for (final major in majors.toList()..sort()) {
    final latest = _tagsForMajor(tags, major).first;
    if (!installed.contains(major)) {
      stdout.writeln('PostgreSQL $major: $latest (available to add)');
      continue;
    }
    final upstreamFile = File('$packageRoot/native/pg$major/UPSTREAM.md');
    final pin = upstreamFile.existsSync()
        ? RegExp(r'- Release tag: \[`([^`]+)`\]')
              .firstMatch(await upstreamFile.readAsString())
              ?.group(1)
        : null;
    if (pin == latest) {
      stdout.writeln('PostgreSQL $major: $latest (installed)');
    } else if (pin != null && _compareTags(latest, pin) > 0) {
      stdout.writeln(
        'PostgreSQL $major: $latest (newer release; installed: $pin)',
      );
    } else {
      stdout.writeln(
        'PostgreSQL $major: $latest (installed: ${pin ?? 'unknown'})',
      );
    }
  }
}

Future<void> _changeVersion(List<String> args) async {
  if (args.isEmpty) {
    throw const FormatException(
      'Missing PostgreSQL major version. Use --help.',
    );
  }
  final major = _parseMajor(args.first);
  final options = <String, String>{};
  var useLatest = false;
  var update = false;
  for (var i = 1; i < args.length; i++) {
    final option = args[i];
    if (option == '--update') {
      if (update) throw const FormatException('Duplicate --update option.');
      update = true;
      continue;
    }
    if (option == '--latest') {
      if (useLatest) throw const FormatException('Duplicate --latest option.');
      useLatest = true;
      continue;
    }
    if (i + 1 >= args.length ||
        !{
          '--tag',
          '--expected-commit',
          '--expected-sha256',
          '--archive',
          '--repository',
          '--releases-json',
        }.contains(option)) {
      throw FormatException('Invalid option: $option. Use --help.');
    }
    if (options.containsKey(option)) {
      throw FormatException('Duplicate option: $option.');
    }
    options[option] = args[++i];
  }
  final repository = options['--repository'] ?? _upstream;
  if (useLatest == options.containsKey('--tag')) {
    throw const FormatException('Choose exactly one of --tag or --latest.');
  }
  final candidateTags = useLatest
      ? _tagsForMajor(
          repository == _upstream || options.containsKey('--releases-json')
              ? await _fetchReleases(options['--releases-json'])
              : await _fetchTags(repository),
          major,
        )
      : [options['--tag']!];
  if (candidateTags.isEmpty) {
    throw FormatException('No stable release tag found for PostgreSQL $major.');
  }
  if (!RegExp('^$major[-.][0-9A-Za-z._-]+\$').hasMatch(candidateTags.first)) {
    throw FormatException('Tag must start with "$major-" or "$major.".');
  }
  final expectedCommit = options['--expected-commit'];
  if (expectedCommit != null &&
      !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(expectedCommit)) {
    throw const FormatException('--expected-commit requires a full Git SHA.');
  }
  final expectedSha256 = options['--expected-sha256'];
  if (expectedSha256 != null &&
      !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedSha256)) {
    throw const FormatException(
      '--expected-sha256 requires a SHA-256 hex digest.',
    );
  }

  final packageRoot = Platform.script.resolve('../').toFilePath();
  final target = Directory('$packageRoot/native/pg$major');
  final versionsFile = File('$packageRoot/native/versions.json');
  final versions = (jsonDecode(await versionsFile.readAsString()) as List)
      .cast<int>()
      .toList();
  if (update) {
    if (!target.existsSync() || !versions.contains(major)) {
      throw FormatException(
        'PostgreSQL $major is not installed. Omit --update to add it.',
      );
    }
    final upstreamFile = File('${target.path}/UPSTREAM.md');
    final pin = RegExp(r'- Release tag: \[`([^`]+)`\]')
        .firstMatch(await upstreamFile.readAsString())
        ?.group(1);
    if (pin == candidateTags.first) {
      stdout.writeln('PostgreSQL $major is already pinned to $pin.');
      return;
    }
    final dirty = await _run('git', [
      '-C',
      packageRoot,
      'status',
      '--porcelain',
      '--',
      'native/pg$major/libpg_query',
      'native/pg$major/UPSTREAM.md',
    ]);
    if (dirty.trim().isNotEmpty) {
      throw FormatException(
        'PostgreSQL $major vendored source or pin has uncommitted changes. '
        'Commit or set them aside before updating.',
      );
    }
  } else {
    if (target.existsSync() || versions.contains(major)) {
      throw FormatException(
        'PostgreSQL $major is already installed. Use --update to change its pin.',
      );
    }
  }

  final temporary = await Directory.systemTemp.createTemp('pg-parser-version-');
  try {
    final archiveOption = options['--archive'];
    final tag = candidateTags.first;
    final archive = File('${temporary.path}/libpg_query-$tag.tar.gz');
    if (archiveOption != null) {
      await File(archiveOption).copy(archive.path);
    }

    final source = Directory('${temporary.path}/source');
    stdout.writeln('Using libpg_query tag $tag.');
    await _run('git', [
      'clone',
      '--depth',
      '1',
      '--single-branch',
      '--branch',
      tag,
      repository,
      source.path,
    ]);
    final commit = (await _run('git', [
      '-C',
      source.path,
      'rev-parse',
      'HEAD',
    ])).trim();
    if (expectedCommit != null &&
        commit.toLowerCase() != expectedCommit.toLowerCase()) {
      throw FormatException(
        'Tag $tag resolved to $commit, expected $expectedCommit.',
      );
    }
    Directory releaseSource;
    String? archiveSha256;
    if (archiveOption != null) {
      archiveSha256 = await _sha256(archive);
      if (expectedSha256 != null &&
          archiveSha256.toLowerCase() != expectedSha256.toLowerCase()) {
        throw FormatException(
          'Release archive SHA-256 is $archiveSha256, expected $expectedSha256.',
        );
      }
      releaseSource = Directory('${temporary.path}/release');
      await releaseSource.create();
      await _run('tar', [
        '-xzf',
        archive.path,
        '--strip-components=1',
        '-C',
        releaseSource.path,
      ]);
    } else {
      if (expectedSha256 != null) {
        throw const FormatException('--expected-sha256 requires --archive.');
      }
      releaseSource = source;
    }
    final runtime = _detectRuntime(releaseSource);
    if (runtime == _ProtobufRuntime.protobufC) {
      await _generateProtobufC(releaseSource);
    }
    _checkUpstream(releaseSource, runtime);
    if (major == 16) {
      final copyright = File('${releaseSource.path}/src/postgres/COPYRIGHT');
      if (!copyright.existsSync()) {
        await File('$packageRoot/tool/licenses/postgresql16_COPYRIGHT')
            .copy(copyright.path);
      }
      await applyMacosStrchrnulFix(releaseSource);
    }
    final patchedPlpgsql = await applyPlpgsqlCompatibilityFix(releaseSource);

    final staged = Directory('${temporary.path}/pg$major');
    final vendored = Directory('${staged.path}/libpg_query');
    await vendored.create(recursive: true);
    for (final path in [
      'LICENSE',
      'pg_query.h',
      if (File('${releaseSource.path}/postgres_deparse.h').existsSync())
        'postgres_deparse.h',
      'protobuf',
      'src',
    ]) {
      await _copy(
        FileSystemEntity.typeSync('${releaseSource.path}/$path') ==
                FileSystemEntityType.directory
            ? Directory('${releaseSource.path}/$path')
            : File('${releaseSource.path}/$path'),
        vendored,
        releaseSource,
      );
    }
    final scanTokensHeader = File(
      '${releaseSource.path}/pg_query_scan_tokens.h',
    );
    if (scanTokensHeader.existsSync()) {
      await _copy(scanTokensHeader, vendored, releaseSource);
    }
    await _copy(
      Directory('${releaseSource.path}/vendor/${runtime.directory}'),
      vendored,
      releaseSource,
    );
    for (final path in ['vendor/xxhash/xxhash.c', 'vendor/xxhash/xxhash.h']) {
      await _copy(File('${releaseSource.path}/$path'), vendored, releaseSource);
    }

    final templateDirectory = update
        ? target
        : Directory('$packageRoot/native/pg17');
    for (final filename in ['bridge.c', 'bridge.h', 'exports.map']) {
      final template = await File('${templateDirectory.path}/$filename')
          .readAsString();
      await File(
        '${staged.path}/$filename',
      ).writeAsString(update ? template : template.replaceAll('17', '$major'));
    }
    final sourceDescription = archiveOption ?? 'Git tag checkout: $repository';
    final checksumLine = archiveSha256 == null
        ? ''
        : '- Source archive SHA-256: `$archiveSha256`\n';
    var patchNote = !patchedPlpgsql
        ? ''
        : '\n## Local compatibility patch\n\n'
              '`src/pg_query_json_plpgsql.c` serializes '
              '`PLPGSQL_DTYPE_PROMISE` with `dump_var`, matching its '
              '`PLpgSQL_var` representation. This fixes malformed JSON '
              'for trigger variables. The upstream pin is unchanged.\n';
    if (major == 16) {
      patchNote +=
          '\nPostgreSQL 16 archives omit `COPYRIGHT`; its retained '
          'notice comes from [PostgreSQL REL_16_1]'
          '(https://github.com/postgres/postgres/blob/REL_16_1/COPYRIGHT). '
          'On macOS, the local `strchrnul` fallback is renamed after system '
          'includes to avoid a collision with the macOS 15.4 SDK while '
          'preserving older deployment targets.\n';
    }
    await File('${staged.path}/UPSTREAM.md')
        .writeAsString('''# Vendored PostgreSQL $major parser source

- Upstream: [pganalyze/libpg_query](https://github.com/pganalyze/libpg_query)
- Release tag: [`$tag`](https://github.com/pganalyze/libpg_query/releases/tag/$tag)
- Commit: `$commit`
- Source: `$sourceDescription`
- Protobuf runtime: `${runtime.directory}`
$checksumLine
$patchNote

`libpg_query/` contains the checked-in source used by the native build. Its
`LICENSE`, PostgreSQL `src/postgres/COPYRIGHT`, and vendored source license
notices are retained. Builds do not fetch source from the network.
''');

    if (update) {
      await _updateInstalledVersion(target, staged, packageRoot, major);
      stdout.writeln('Updated PostgreSQL $major to $tag ($commit).');
      return;
    }

    await installStagedVersion(
      staged: staged,
      packageRoot: packageRoot,
      major: major,
    );

    stdout.writeln('Added PostgreSQL $major from $tag ($commit).');
    stdout.writeln(
      'Review native/pg$major/UPSTREAM.md and run dart analyze, dart test on macOS and Linux.',
    );
    stdout.writeln('Add a PostgreSQL $major syntax test before release.');
  } finally {
    await temporary.delete(recursive: true);
  }
}

/// Installs a staged bridge and source, rolling back if bindings cannot generate.
Future<void> installStagedVersion({
  required Directory staged,
  required String packageRoot,
  required int major,
}) async {
  final target = Directory('$packageRoot/native/pg$major');
  final versionsFile = File('$packageRoot/native/versions.json');
  final versions = (jsonDecode(await versionsFile.readAsString()) as List)
      .cast<int>()
      .toList();
  if (target.existsSync() || versions.contains(major)) {
    throw FormatException('PostgreSQL $major is already installed.');
  }
  final backendTemplate = await File('$packageRoot/lib/src/backends/pg17.dart')
      .readAsString();
  final backendFile = File('$packageRoot/lib/src/backends/pg$major.dart');
  final nativeFile = File('$packageRoot/lib/src/native/pg$major.dart');
  if (backendFile.existsSync() || nativeFile.existsSync()) {
    throw FormatException('Dart files for PostgreSQL $major already exist.');
  }

  final versionFile = File('$packageRoot/lib/src/postgres_version.dart');
  final parserFile = File('$packageRoot/lib/src/postgres_parser.dart');
  final oldVersion = await versionFile.readAsString();
  final oldParser = await parserFile.readAsString();
  final newVersion = _insert(
    oldVersion,
    'VERSION CONSTANTS',
    '  /// PostgreSQL $major grammar.\n'
        '  static const v$major = PostgresVersion._($major);\n',
  );
  var newParser = _insert(
    oldParser,
    'BACKEND IMPORTS',
    "import 'backends/pg$major.dart';\n",
  );
  newParser = _insert(
    newParser,
    'SUPPORTED VERSIONS',
    '    PostgresVersion.v$major,\n',
  );
  newParser = _insert(
    newParser,
    'BACKEND REGISTRY',
    '    $major: Pg${major}Backend(),\n',
  );
  versions.add(major);
  versions.sort();

  final originals = <File, String>{
    versionFile: oldVersion,
    parserFile: oldParser,
    versionsFile: await versionsFile.readAsString(),
  };
  try {
    await staged.rename(target.path);
    await backendFile.writeAsString(backendTemplate.replaceAll('17', '$major'));
    await generateBindings(
      major: major,
      header: File('${target.path}/bridge.h').uri,
      output: nativeFile.uri,
    );
    await versionFile.writeAsString(newVersion);
    await parserFile.writeAsString(newParser);
    await versionsFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(versions)}\n',
    );
  } catch (_) {
    for (final entry in originals.entries) {
      await entry.key.writeAsString(entry.value);
    }
    if (target.existsSync()) await target.delete(recursive: true);
    if (backendFile.existsSync()) await backendFile.delete();
    if (nativeFile.existsSync()) await nativeFile.delete();
    rethrow;
  }
}

/// Repairs serializers that omit promise datums used by trigger variables.
/// Both ordinary variables and promise datums use the PLpgSQL_var struct.
Future<bool> applyPlpgsqlCompatibilityFix(Directory source) async {
  final serializer = File('${source.path}/src/pg_query_json_plpgsql.c');
  final original = await serializer.readAsString();
  final updated = original.replaceAllMapped(
    RegExp(
      r'^([\t ]*)((?:case PLPGSQL_DTYPE_(?:VAR|PROMISE):\n[\t ]*)+)'
      r'dump_var\(out, \(PLpgSQL_var \*\) (?:d|node)\);',
      multiLine: true,
    ),
    (match) => match[0]!.contains('case PLPGSQL_DTYPE_PROMISE:')
        ? match[0]!
        : match[0]!.replaceFirst(
            'case PLPGSQL_DTYPE_VAR:\n',
            'case PLPGSQL_DTYPE_VAR:\n${match[1]}case PLPGSQL_DTYPE_PROMISE:\n',
          ),
  );
  if (updated == original) return false;
  await serializer.writeAsString(updated);
  return true;
}

/// PG16 predates the macOS 15.4 strchrnul declaration. Rename its local
/// fallback after system includes so older deployment targets still work.
Future<void> applyMacosStrchrnulFix(Directory source) async {
  final file = File('${source.path}/src/postgres/src_port_snprintf.c');
  final original = await file.readAsString();
  if (original.contains('#define strchrnul pgp16_strchrnul')) return;
  await file.writeAsString(
    original.replaceFirst(
      '#ifndef HAVE_STRCHRNUL',
      '#if defined(__APPLE__) && !defined(HAVE_STRCHRNUL)\n'
          '#define strchrnul pgp16_strchrnul\n#endif\n\n#ifndef HAVE_STRCHRNUL',
    ),
  );
}

Future<void> _updateInstalledVersion(
  Directory target,
  Directory staged,
  String packageRoot,
  int major,
) async {
  final installedSource = Directory('${target.path}/libpg_query');
  final installedPin = File('${target.path}/UPSTREAM.md');
  if (!installedSource.existsSync() || !installedPin.existsSync()) {
    throw FormatException('PostgreSQL $major installation is incomplete.');
  }

  final oldPin = await installedPin.readAsString();
  final newPin = await File('${staged.path}/UPSTREAM.md').readAsString();
  final exchange = await target.parent.createTemp('.pg$major-update-');
  final replacement = Directory('${exchange.path}/replacement');
  final previous = Directory('${exchange.path}/previous');
  var movedPrevious = false;
  var validated = false;
  try {
    await replacement.create();
    final source = Directory('${staged.path}/libpg_query');
    await _copy(source, replacement, source);
    await installedSource.rename(previous.path);
    movedPrevious = true;
    await replacement.rename(installedSource.path);
    await installedPin.writeAsString(newPin);

    stdout.writeln(
      'Validating PostgreSQL $major with dart analyze and dart test.',
    );
    await _run(Platform.resolvedExecutable, [
      'analyze',
    ], workingDirectory: packageRoot);
    await _run(Platform.resolvedExecutable, [
      'test',
    ], workingDirectory: packageRoot);
    validated = true;
  } catch (_) {
    if (movedPrevious) {
      if (installedSource.existsSync()) {
        await installedSource.delete(recursive: true);
      }
      await previous.rename(installedSource.path);
      await installedPin.writeAsString(oldPin);
    }
    rethrow;
  } finally {
    // Keep the original source on disk if restoring it failed.
    if (exchange.existsSync() && (validated || !previous.existsSync())) {
      await exchange.delete(recursive: true);
    }
  }
}

enum _ProtobufRuntime {
  protobufC('protobuf-c'),
  upb('upb');

  const _ProtobufRuntime(this.directory);
  final String directory;
}

_ProtobufRuntime _detectRuntime(Directory source) {
  if (File('${source.path}/vendor/upb/upb.c').existsSync()) {
    return _ProtobufRuntime.upb;
  }
  if (File('${source.path}/vendor/protobuf-c/protobuf-c.c').existsSync()) {
    return _ProtobufRuntime.protobufC;
  }
  throw const FormatException(
    'Unknown libpg_query Protobuf runtime. Update the native build hook for '
    'this release before adding it.',
  );
}

void _checkUpstream(Directory source, _ProtobufRuntime runtime) {
  for (final path in [
    'LICENSE',
    'pg_query.h',
    if (!File('${source.path}/pg_query.h')
        .readAsStringSync()
        .contains('#define PG_MAJORVERSION "16"'))
      'src/postgres/COPYRIGHT',
    'src/pg_query_parse.c',
    'src/pg_query_parse_plpgsql.c',
    'src/pg_query_json_plpgsql.c',
    'src/postgres/src_backend_parser_gram.c',
    'vendor/xxhash/xxhash.c',
    if (runtime == _ProtobufRuntime.protobufC) ...[
      'protobuf/pg_query.pb-c.c',
      'protobuf/pg_query.pb-c.h',
      'vendor/protobuf-c/protobuf-c.c',
    ] else ...[
      'protobuf/pg_query.upb.h',
      'protobuf/pg_query.upb_minitable.c',
      'protobuf/pg_query.upb_minitable.h',
      'vendor/upb/upb.c',
      'vendor/upb/third_party/utf8_range/utf8_range.c',
      'pg_query_scan_tokens.h',
    ],
  ]) {
    if (!File('${source.path}/$path').existsSync()) {
      throw FormatException(
        'Upstream release is missing $path. Review its layout.',
      );
    }
  }
  final header = File('${source.path}/pg_query.h').readAsStringSync();
  if (!header.contains('pg_query_parse(') ||
      !header.contains('pg_query_free_parse_result(') ||
      !header.contains('pg_query_parse_plpgsql(') ||
      !header.contains('pg_query_free_plpgsql_parse_result(')) {
    throw const FormatException(
      'Upstream parse API changed; update the bridge manually.',
    );
  }
}

Future<void> _generateProtobufC(Directory source) async {
  final generatedC = File('${source.path}/protobuf/pg_query.pb-c.c');
  final generatedH = File('${source.path}/protobuf/pg_query.pb-c.h');
  if (generatedC.existsSync() && generatedH.existsSync()) return;
  if (!File('${source.path}/vendor/protobuf-c/protobuf-c.c').existsSync()) {
    throw const FormatException(
      'This libpg_query tag does not use the expected protobuf-c layout. '
      'The native build hook needs a version-specific update.',
    );
  }
  if (!File('${source.path}/protobuf/pg_query.proto').existsSync()) {
    throw const FormatException(
      'Upstream source is missing protobuf/pg_query.proto.',
    );
  }
  stdout.writeln('Generating protobuf C sources with protoc and protoc-gen-c.');
  try {
    final result = await Process.run('protoc', [
      '--c_out=.',
      'protobuf/pg_query.proto',
    ], workingDirectory: source.path);
    if (result.exitCode != 0) {
      throw FormatException(
        'Could not generate protobuf C sources. Install protoc and '
        'protoc-gen-c (protobuf-c compiler), then retry.\n'
        '${result.stdout}${result.stderr}',
      );
    }
  } on ProcessException catch (error) {
    throw FormatException(
      'Could not run protoc ($error). Install protoc and protoc-gen-c '
      '(protobuf-c compiler), then retry.',
    );
  }
  if (!generatedC.existsSync() || !generatedH.existsSync()) {
    throw const FormatException(
      'protoc did not produce protobuf/pg_query.pb-c.c and .h.',
    );
  }
}

Future<void> _copy(
  FileSystemEntity entity,
  Directory destination,
  Directory source,
) async {
  if (entity is Directory) {
    for (final child in entity.listSync(followLinks: false)) {
      await _copy(child, destination, source);
    }
  } else if (entity is File) {
    final relative = entity.path.substring(source.path.length + 1);
    final target = File('${destination.path}/$relative');
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  } else {
    throw FormatException('Unexpected upstream link: ${entity.path}');
  }
}

Future<String> _sha256(File archive) async {
  for (final command in [
    ['shasum', '-a', '256', archive.path],
    ['sha256sum', archive.path],
  ]) {
    try {
      final output = await _run(command.first, command.skip(1).toList());
      return output.trim().split(RegExp(r'\s+')).first;
    } on ProcessException {
      continue;
    }
  }
  throw const FormatException('SHA-256 tool not found (shasum or sha256sum).');
}

String _insert(String source, String section, String addition) {
  final begin = RegExp(
    '^ *// BEGIN GENERATED ${RegExp.escape(section)}\$',
    multiLine: true,
  );
  final end = RegExp(
    '^ *// END GENERATED ${RegExp.escape(section)}\$',
    multiLine: true,
  );
  final beginnings = begin.allMatches(source).toList();
  final endings = end.allMatches(source).toList();
  if (beginnings.length != 1 ||
      endings.length != 1 ||
      beginnings.single.start >= endings.single.start) {
    throw FormatException('Missing or duplicate generated section: $section');
  }
  return source.replaceRange(
    endings.single.start,
    endings.single.start,
    addition,
  );
}

Future<String> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}
