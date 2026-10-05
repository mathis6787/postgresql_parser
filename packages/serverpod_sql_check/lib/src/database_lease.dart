import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

import 'database_check.dart';
import 'database_helpers.dart';
import 'database_project.dart';

String endpointUrl(Endpoint endpoint, {bool requireSsl = false}) => Uri(
  scheme: 'postgresql',
  path: '/${endpoint.database}',
  queryParameters: {
    'host': endpoint.host,
    'port': '${endpoint.port}',
    if (endpoint.username != null) 'user': endpoint.username!,
    if (endpoint.password != null) 'password': endpoint.password!,
    'sslmode': requireSsl ? 'require' : 'disable',
  },
).toString();

/// Owns only resources created by this invocation. Never stops project servers.
final class DatabaseLease {
  DatabaseLease();
  late String target, backend;
  String? mode, searchPath;
  late String url;
  Endpoint? endpoint;
  DatabaseProject? project;
  Duration startup = Duration.zero, preparation = Duration.zero;
  final _processes = <Process>{};
  final _secrets = <String>[];
  Directory? _scratch, _helpers;
  String? _container;
  Process? _embedded;
  Future<void>? _closing;
  bool interrupted = false;

  String redact(String value) {
    for (final secret
        in _secrets.where((s) => s.isNotEmpty).toList()
          ..sort((a, b) => b.length.compareTo(a.length))) {
      value = value.replaceAll(secret, '[redacted]');
      value = value.replaceAll(Uri.encodeComponent(secret), '[redacted]');
    }
    return value.replaceAll(
      RegExp(r'postgres(?:ql)?://[^\s]+'),
      '[redacted connection]',
    );
  }

  Future<void> open(
    DatabaseOptions options,
    Directory scanRoot,
    Map<String, String> environment,
  ) async {
    target = options.resolveTarget(environment);
    final suppliedUrl = environment[options.urlEnv];
    if (suppliedUrl != null && suppliedUrl.trim().isNotEmpty) {
      backend = 'url';
      url = suppliedUrl;
      searchPath = options.searchPath;
      return;
    }
    mode = options.mode ?? (target == 'temporary' ? 'test' : 'development');
    project = DatabaseProject.load(scanRoot, mode!, environment);
    searchPath = options.searchPath ?? project!.postgresSearchPath;
    _secrets.add(project!.endpoint.password ?? '');
    backend = target == 'existing'
        ? (project!.dataPath == null ? 'tcp' : 'embedded')
        : options.image != null
        ? 'docker'
        : options.backend == 'auto'
        ? (project!.dataPath == null ? 'docker' : 'embedded')
        : options.backend;
    if (target == 'existing' && backend == 'tcp') {
      endpoint = project!.endpoint;
      url = endpointUrl(endpoint!, requireSsl: project!.requireSsl);
      return;
    }
    project!.preflight(
      migrations: target == 'temporary',
      embedded: backend == 'embedded',
      setup: options.setup,
    );
    final helperRoot = await Directory(
      p.join(project!.root.path, '.dart_tool', 'serverpod_sql_check'),
    ).create(recursive: true);
    _helpers = await helperRoot.createTemp('run-');
    final watch = Stopwatch()..start();
    if (backend == 'embedded') {
      await _openEmbedded();
    } else {
      await _openDocker(options.image);
    }
    startup = watch.elapsed;
    url = endpointUrl(endpoint!);
    _secrets.add(url);
  }

  String get _dart => Platform.resolvedExecutable.endsWith('/dart')
      ? Platform.resolvedExecutable
      : 'dart';

  Future<ProcessResult> _run(
    String executable,
    List<String> args, {
    Duration timeout = const Duration(seconds: 120),
    Map<String, String>? environment,
    String? input,
    String? cwd,
  }) async {
    if (interrupted) {
      throw const DatabaseCheckException('Database operation interrupted.');
    }
    Process process;
    try {
      process = await Process.start(
        executable,
        args,
        workingDirectory: cwd ?? project?.root.path,
        environment: environment,
      );
    } catch (_) {
      throw DatabaseCheckException(
        'Could not start $executable. Check that it is installed and available on PATH.',
      );
    }
    _processes.add(process);
    final out = StringBuffer();
    final err = StringBuffer();
    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .listen(out.write);
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(err.write);
    final completion = Future.wait([
      process.exitCode,
      stdoutSubscription.asFuture<int>(0),
      stderrSubscription.asFuture<int>(0),
    ]);
    try {
      if (input != null) process.stdin.write(input);
      await process.stdin.close();
      // Include draining output: a hook's subprocess may inherit its pipes.
      final codes = await completion.timeout(timeout);
      return ProcessResult(
        process.pid,
        codes.first,
        out.toString(),
        err.toString(),
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
      throw const DatabaseCheckException(
        'Database startup or preparation timed out.',
      );
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      _processes.remove(process);
    }
  }

  Future<void> _openEmbedded() async {
    final helper = File(p.join(_helpers!.path, 'embedded.dart'));
    await helper.writeAsString(embeddedHelper);
    if (target == 'temporary') {
      _scratch = await Directory('/tmp').createTemp('sql-check-pg-');
    }
    final nonce = _nonce();
    final password = _nonce();
    _secrets.add(password);
    final process = await Process.start(_dart, [
      'run',
      helper.path,
    ], workingDirectory: project!.root.path);
    _embedded = process;
    final ready = Completer<Map>();
    String? lastProgress;
    process.stderr.transform(utf8.decoder).listen((_) {});
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!line.startsWith('SQL_CHECK_EVENT ')) return;
          try {
            final event =
                jsonDecode(line.substring('SQL_CHECK_EVENT '.length)) as Map;
            if (event.containsKey('progress')) {
              final progress = '${event['progress']}';
              if (progress != lastProgress) {
                stdout.writeln('Embedded PostgreSQL: $progress.');
                lastProgress = progress;
              }
            } else if (!ready.isCompleted) {
              if (event.containsKey('error')) {
                ready.completeError(
                  const DatabaseCheckException(
                    'Embedded PostgreSQL is unavailable. For an existing database, start the server or use serverpod database start. For a temporary instance, check the binary cache and supported version.',
                  ),
                );
              } else {
                ready.complete(event);
              }
            }
          } catch (_) {
            if (!ready.isCompleted) {
              ready.completeError(
                const DatabaseCheckException(
                  'Invalid embedded PostgreSQL helper response.',
                ),
              );
            }
          }
        });
    unawaited(
      process.exitCode.then((_) {
        if (!ready.isCompleted) {
          ready.completeError(
            const DatabaseCheckException(
              'Embedded PostgreSQL helper failed. Check the project dependencies and binary cache.',
            ),
          );
        }
      }),
    );
    process.stdin.writeln(
      jsonEncode({
        'start': target == 'temporary',
        'dataDir': _scratch == null
            ? project!.dataPath
            : p.join(_scratch!.path, 'pgdata'),
        'database': target == 'temporary'
            ? 'sql_check_$nonce'
            : project!.endpoint.database,
        'user': project!.endpoint.username,
        'password': target == 'temporary'
            ? password
            : project!.endpoint.password,
      }),
    );
    final info = await ready.future.timeout(const Duration(minutes: 5));
    var host = info['host'] as String;
    // Unix sockets have a platform path-length limit. A private short alias
    // also allows the checker to run outside the server package's directory.
    if (info['unix'] == true && host.length > 90) {
      _scratch ??= await Directory('/tmp').createTemp('sql-check-socket-');
      final alias = Link(p.join(_scratch!.path, 'socket'));
      await alias.create(host);
      host = p.relative(alias.path, from: Directory.current.path);
      if (host.length > 90) host = alias.path;
    }
    endpoint = Endpoint(
      host: host,
      port: info['port'] as int,
      database: info['database'] as String,
      username: info['user'] as String,
      password: info['password'] as String?,
      isUnixSocket: info['unix'] as bool,
    );
    _secrets.add(endpoint!.password ?? '');
  }

  Future<void> _openDocker(String? image) async {
    if (image == null) {
      final result = await _run('docker', [
        'compose',
        'config',
        '--format',
        'json',
      ]);
      if (result.exitCode != 0) {
        throw const DatabaseCheckException(
          'Cannot resolve Docker Compose configuration. Check Docker and Compose, or supply --database-docker-image.',
        );
      }
      try {
        image = selectDockerImage(
          jsonDecode(result.stdout as String) as Map,
          project!,
        );
      } on DatabaseCheckException {
        rethrow;
      } catch (_) {
        throw const DatabaseCheckException(
          'Invalid Docker Compose configuration.',
        );
      }
    }
    final local = await _run('docker', [
      'image',
      'inspect',
      '--format',
      '{{.Id}}',
      image,
    ]);
    if (local.exitCode != 0) {
      final pull = await _run('docker', [
        'pull',
        image,
      ], timeout: const Duration(minutes: 5));
      if (pull.exitCode != 0) {
        throw const DatabaseCheckException(
          'Could not obtain the PostgreSQL Docker image. Build the local image first, or check Docker, the image and registry access.',
        );
      }
    }
    final nonce = _nonce();
    _container = 'serverpod-sql-check-$nonce';
    final password = _nonce();
    _secrets.add(password);
    final result = await _run(
      'docker',
      [
        'run',
        '--detach',
        '--rm',
        '--name',
        _container!,
        '--label',
        'serverpod_sql_check.run=$nonce',
        '--publish',
        '127.0.0.1::5432',
        '--env',
        'POSTGRES_USER',
        '--env',
        'POSTGRES_PASSWORD',
        '--env',
        'POSTGRES_DB',
        image,
      ],
      environment: {
        'POSTGRES_USER': project!.endpoint.username!,
        'POSTGRES_PASSWORD': password,
        'POSTGRES_DB': 'sql_check_$nonce',
      },
    );
    if (result.exitCode != 0) {
      throw const DatabaseCheckException(
        'Could not start the isolated PostgreSQL Docker container.',
      );
    }
    final ports = await _run('docker', ['port', _container!, '5432/tcp']);
    final match = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch('${ports.stdout}');
    if (ports.exitCode != 0 || match == null) {
      throw const DatabaseCheckException(
        'Could not discover the isolated PostgreSQL Docker port.',
      );
    }
    endpoint = Endpoint(
      host: '127.0.0.1',
      port: int.parse(match.group(1)!),
      database: 'sql_check_$nonce',
      username: project!.endpoint.username,
      password: password,
    );
    final wait = Stopwatch()..start();
    while (wait.elapsed < const Duration(seconds: 120) && !interrupted) {
      try {
        final connection = await Connection.open(
          endpoint!,
          settings: const ConnectionSettings(
            sslMode: SslMode.disable,
            connectTimeout: Duration(seconds: 2),
          ),
        );
        await connection.close();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw const DatabaseCheckException(
      'The isolated PostgreSQL Docker instance did not become ready.',
    );
  }

  Future<void> prepare(String? setup) async {
    if (target != 'temporary') return;
    final watch = Stopwatch()..start();
    final project = this.project!;
    Future<void> hook(String phase) async {
      if (setup == null) return;
      final result = await _run(
        _dart,
        ['run', p.join(project.root.path, setup), '--phase=$phase'],
        environment: {'SQL_CHECK_DATABASE_URL': url},
      );
      if (result.exitCode != 0) {
        throw DatabaseCheckException(
          'Database setup failed ($phase): ${redact('${result.stderr}${result.stdout}')}',
        );
      }
    }

    await hook('before-migrations');
    final helper = File(p.join(_helpers!.path, 'migrate.dart'));
    await helper.writeAsString(
      migrationHelper(
        protocol: project.generatedImport('protocol.dart'),
        endpoints: project.generatedImport('endpoints.dart'),
      ),
    );
    final result = await _run(
      _dart,
      ['run', helper.path],
      input: jsonEncode({
        'host': endpoint!.host,
        'port': endpoint!.port,
        'database': endpoint!.database,
        'user': endpoint!.username,
        'password': endpoint!.password,
        'unix': endpoint!.isUnixSocket,
        'searchPath': searchPath,
      }),
    );
    if (result.exitCode != 0) {
      throw DatabaseCheckException(
        'Serverpod migration preparation failed: ${redact('${result.stderr}${result.stdout}')}',
      );
    }
    await hook('after-migrations');
    preparation = watch.elapsed;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    interrupted = true;
    Object? failure;
    for (final process in _processes.toList()) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } catch (error) {
          failure = error;
        }
      }
    }
    if (_embedded case final Process process) {
      try {
        process.stdin.writeln('stop');
        await process.stdin.close();
        final code = await process.exitCode.timeout(
          const Duration(seconds: 20),
        );
        if (code != 0) {
          throw const DatabaseCheckException(
            'Embedded PostgreSQL helper shutdown failed.',
          );
        }
      } catch (error) {
        process.kill(ProcessSignal.sigterm);
        failure = error;
      }
    }
    if (_container case final String name) {
      try {
        final result = await Process.run('docker', [
          'rm',
          '--force',
          '--volumes',
          name,
        ]).timeout(const Duration(seconds: 20));
        if (result.exitCode != 0 &&
            !'${result.stderr}'.contains('No such container')) {
          throw const DatabaseCheckException(
            'Could not remove the checker-owned Docker container.',
          );
        }
      } catch (error) {
        failure = error;
      }
    }
    for (final directory in [_scratch, _helpers]) {
      if (directory != null && directory.existsSync()) {
        try {
          await directory.delete(recursive: true);
        } catch (error) {
          failure = error;
        }
      }
    }
    if (failure != null) {
      throw const DatabaseCheckException(
        'Could not clean up all checker-owned database resources.',
      );
    }
  }
}

String _nonce() => List.generate(
  12,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
