import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';
import 'package:yaml/yaml.dart';

import 'database_check.dart';
import 'server_discovery.dart';

final class DatabaseOptions {
  DatabaseOptions({
    this.target,
    this.backend = 'auto',
    this.mode,
    this.image,
    this.setup,
    this.urlEnv = 'SQL_CHECK_DATABASE_URL',
    this.searchPath,
    this.explicitUrlEnv = false,
  });
  final String? target, mode, image, setup, searchPath;
  final String backend, urlEnv;
  final bool explicitUrlEnv;

  String resolveTarget(Map<String, String> environment) {
    final url = environment[urlEnv];
    final hasUrl = url != null && url.trim().isNotEmpty;
    if (target != null && !{'temporary', 'existing'}.contains(target) ||
        !{'auto', 'embedded', 'docker'}.contains(backend) ||
        mode != null && !{'test', 'development'}.contains(mode) ||
        image != null && (image!.trim().isEmpty || image!.contains('\u0000')) ||
        setup != null && (setup!.isEmpty || setup!.contains('\u0000'))) {
      throw const DatabaseCheckException(
        'Invalid database target, backend, mode, image or setup option.',
      );
    }
    if (explicitUrlEnv && !hasUrl) {
      throw DatabaseCheckException(
        'Set $urlEnv to a prepared test database connection URL.',
      );
    }
    if (target == 'temporary' && hasUrl) {
      throw DatabaseCheckException(
        'Unset $urlEnv when explicitly requesting a temporary database.',
      );
    }
    final resolved = target ?? (hasUrl ? 'existing' : 'temporary');
    if (resolved == 'existing' &&
        (backend != 'auto' || image != null || setup != null)) {
      throw const DatabaseCheckException(
        'Backend, image and setup options require a temporary database.',
      );
    }
    if (image != null && backend == 'embedded') {
      throw const DatabaseCheckException(
        'A Docker image cannot be used with the embedded backend.',
      );
    }
    return resolved;
  }
}

/// Reads only declarative connection settings. Application startup is not run.
final class DatabaseProject {
  DatabaseProject._(
    this.root,
    this.mode,
    this.endpoint,
    this.dataPath,
    this.searchPath,
  );
  final Directory root;
  final String mode;
  final Endpoint endpoint;
  final String? dataPath, searchPath;
  // Serverpod treats each comma-separated config entry as a schema name.
  // Quote those names before passing them to PostgreSQL's search_path parser.
  String? get postgresSearchPath {
    final value = searchPath;
    if (value == null || value.trim().isEmpty) return value?.trim();
    return value
        .split(',')
        .map((entry) {
          final name = entry.trim().replaceAll('"', '""');
          return '"$name"';
        })
        .join(', ');
  }

  bool requireSsl = false;
  Map<String, Uri>? packages;
  String? _packageName;
  Uri? _packageLibrary;

  String generatedImport(String fileName) {
    if (_packageName == null || _packageLibrary == null) {
      throw const DatabaseCheckException(
        'The server package is missing from its dependency configuration. Run dart pub get.',
      );
    }
    final relative = p.relative(
      p.join(root.path, 'lib', 'src', 'generated', fileName),
      from: p.fromUri(_packageLibrary!),
    );
    if (p.isAbsolute(relative) || p.split(relative).first == '..') {
      throw const DatabaseCheckException(
        'Generated Serverpod files are outside the resolved package library.',
      );
    }
    return Uri(
      scheme: 'package',
      path: '$_packageName/${p.split(relative).join('/')}',
    ).toString();
  }

  static DatabaseProject load(
    Directory start,
    String mode,
    Map<String, String> environment,
  ) {
    final Directory root;
    try {
      root = discoverServer(start);
    } on ServerDiscoveryException catch (error) {
      throw DatabaseCheckException(error.message);
    }
    final config = readYamlMap(File(p.join(root.path, 'config', '$mode.yaml')));
    final raw = config['database'];
    if (raw is! Map) {
      throw DatabaseCheckException(
        'No PostgreSQL database configuration in config/$mode.yaml.',
      );
    }
    final passwords = readYamlMap(
      File(p.join(root.path, 'config', 'passwords.yaml')),
      optional: true,
    );
    Object? setting(String field, String suffix) =>
        environment['SERVERPOD_DATABASE_$suffix'] ?? raw[field];
    String text(String field, String suffix, {String? fallback}) {
      final value = setting(field, suffix) ?? fallback;
      if (value is! String || value.isEmpty || value.contains('\u0000')) {
        throw DatabaseCheckException(
          'Invalid or missing database $field in config/$mode.yaml.',
        );
      }
      return value;
    }

    bool flag(String field, String suffix) {
      final value = setting(field, suffix) ?? false;
      if (value != true &&
          value != false &&
          value != 'true' &&
          value != 'false') {
        throw DatabaseCheckException('Invalid database $field.');
      }
      return value == true || value == 'true';
    }

    final dialect = setting('dialect', 'DIALECT');
    if (dialect != null && dialect != 'postgres') {
      throw const DatabaseCheckException(
        'Database validation requires PostgreSQL.',
      );
    }
    final portValue = setting('port', 'PORT');
    final port = portValue is int ? portValue : int.tryParse('$portValue');
    if (port == null || port < 1 || port > 65535) {
      throw const DatabaseCheckException('Invalid or missing database port.');
    }
    final shared = passwords['shared'];
    final selected = passwords[mode];
    final password =
        environment['SERVERPOD_PASSWORD_database'] ??
        environment['SERVERPOD_DATABASE_PASSWORD'] ??
        (selected is Map ? selected['database'] : null) ??
        (shared is Map ? shared['database'] : null) ??
        '';
    if (password is! String || password.contains('\u0000')) {
      throw const DatabaseCheckException(
        'Invalid database password configuration.',
      );
    }
    final data = setting('dataPath', 'DATA_PATH');
    final search = setting('searchPaths', 'SEARCH_PATHS');
    if (data != null && data is! String ||
        search != null && search is! String ||
        data is String && data.contains('\u0000') ||
        search is String && search.contains('\u0000')) {
      throw const DatabaseCheckException(
        'Invalid database dataPath or searchPaths.',
      );
    }
    final result = DatabaseProject._(
      root,
      mode,
      Endpoint(
        host: flag('isUnixSocket', 'IS_UNIX_SOCKET')
            ? p.normalize(p.join(root.path, text('host', 'HOST')))
            : text('host', 'HOST'),
        port: port,
        database: text('name', 'NAME'),
        username: text('user', 'USER'),
        password: password,
        isUnixSocket: flag('isUnixSocket', 'IS_UNIX_SOCKET'),
      ),
      data is String && data.trim().isNotEmpty
          ? p.normalize(p.join(root.path, data.trim()))
          : null,
      search as String?,
    );
    result.requireSsl = flag('requireSsl', 'REQUIRE_SSL');
    return result;
  }

  void preflight({
    required bool migrations,
    required bool embedded,
    String? setup,
  }) {
    final file = File(p.join(root.path, '.dart_tool', 'package_config.json'));
    if (!file.existsSync()) {
      throw const DatabaseCheckException(
        'Project dependencies are missing. Run dart pub get in the server package.',
      );
    }
    try {
      final config = jsonDecode(file.readAsStringSync()) as Map;
      packages = {
        for (final entry in config['packages'] as List)
          entry['name'] as String: Directory.fromUri(
            file.uri.resolve(entry['rootUri'] as String),
          ).uri,
      };
      final serverpod = packages!['serverpod'];
      if (serverpod == null) throw const FormatException();
      final version =
          readYamlMap(
                File.fromUri(serverpod.resolve('pubspec.yaml')),
              )['version']
              as String;
      if (!RegExp(r'^(3\.4\.|4\.)').hasMatch(version)) {
        throw const DatabaseCheckException(
          'Automatic database setup supports Serverpod 3.4 and 4.x. Use an explicit URL for other versions.',
        );
      }
      if (embedded && !packages!.containsKey('serverpod_embedded_postgres')) {
        throw const DatabaseCheckException(
          'The project has no resolved serverpod_embedded_postgres dependency. Use Docker or update the Serverpod project.',
        );
      }
      if (migrations) {
        for (final entry in config['packages'] as List) {
          final name = entry['name'] as String;
          if (p.equals(p.normalize(p.fromUri(packages![name]!)), root.path)) {
            _packageName = name;
            _packageLibrary = packages![name]!.resolve(
              entry['packageUri'] as String? ?? 'lib/',
            );
            break;
          }
        }
        // Use package URIs consistently with the application's own imports.
        generatedImport('protocol.dart');
        for (final name in ['protocol.dart', 'endpoints.dart']) {
          if (!File(p.join(root.path, 'lib', 'src', 'generated', name))
              .existsSync()) {
            throw const DatabaseCheckException(
              'Generated Protocol or Endpoints are missing. Run serverpod generate.',
            );
          }
        }
        if (!File(p.join(root.path, 'migrations', 'migration_registry.txt'))
            .existsSync()) {
          throw const DatabaseCheckException(
            'Serverpod migrations are missing. Create a migration before validating a temporary database.',
          );
        }
      }
      if (setup != null && !File(p.join(root.path, setup)).existsSync()) {
        throw const DatabaseCheckException(
          'The database setup Dart file does not exist.',
        );
      }
    } on DatabaseCheckException {
      rethrow;
    } catch (_) {
      throw const DatabaseCheckException(
        'Cannot read the project dependency configuration. Run dart pub get.',
      );
    }
  }
}

Map readYamlMap(File file, {bool optional = false}) {
  if (!file.existsSync()) {
    if (optional) return {};
    throw DatabaseCheckException('Missing configuration file: ${file.path}.');
  }
  try {
    final value = loadYaml(file.readAsStringSync());
    if (value is! Map) throw const FormatException();
    return value;
  } catch (_) {
    // YAML exception snippets can contain credentials.
    throw DatabaseCheckException(
      'Cannot read YAML configuration: ${file.path}.',
    );
  }
}

/// Compose's resolved JSON remains private: it may contain substituted secrets.
String selectDockerImage(Map compose, DatabaseProject project) {
  final services = compose['services'];
  final matches = <String>[];
  if (services is Map) {
    for (final service in services.values.whereType<Map>()) {
      final env = service['environment'];
      final ports = service['ports'];
      final nameMatches =
          env is Map && env['POSTGRES_DB'] == project.endpoint.database;
      final portMatches =
          ports is List &&
          ports.whereType<Map>().any(
            (port) =>
                '${port['published']}' == '${project.endpoint.port}' &&
                '${port['target']}' == '5432',
          );
      if (nameMatches || portMatches) {
        if (service['image'] case final String image) {
          matches.add(image);
        } else {
          throw const DatabaseCheckException(
            'The PostgreSQL Compose service has no image. Supply --database-docker-image.',
          );
        }
      }
    }
  }
  if (matches.length != 1) {
    throw const DatabaseCheckException(
      'PostgreSQL Compose service is missing or ambiguous. Supply --database-docker-image.',
    );
  }
  return matches.single;
}
