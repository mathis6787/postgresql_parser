/// Helpers run with the project's resolved Serverpod dependencies, not ours.
library;

const embeddedHelper = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:serverpod_embedded_postgres/serverpod_embedded_postgres.dart';

Future<void> main() async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  final iterator = StreamIterator(lines);
  EmbeddedPostgres? pg;
  var owned = false;
  try {
    if (!await iterator.moveNext()) return;
    final config = jsonDecode(iterator.current) as Map;
    owned = config['start'] == true;
    pg = owned
        ? await EmbeddedPostgres.start(EmbeddedPostgresOptions(
            dataDir: Directory(config['dataDir'] as String),
            databaseName: config['database'] as String,
            username: config['user'] as String,
            transport: UnixTransport(initialPassword: config['password'] as String),
            onProgress: (fraction, stage) {
              stdout.writeln('SQL_CHECK_EVENT ${jsonEncode({'progress': stage})}');
            },
          ))
        : await EmbeddedPostgres.attach(Directory(config['dataDir'] as String));
    final endpoint = pg.endpoint;
    stdout.writeln('SQL_CHECK_EVENT ${jsonEncode({
      'host': endpoint.isUnixSocket ? File(endpoint.host).absolute.path : endpoint.host,
      'port': endpoint.port,
      'database': config['database'],
      'user': config['user'],
      'password': endpoint.password ?? config['password'],
      'unix': endpoint.isUnixSocket,
    })}');
    await stdout.flush();
    // The parent keeps stdin open while it owns this lease. EOF also cleans up.
    while (await iterator.moveNext()) {
      if (iterator.current == 'stop') break;
    }
  } catch (_) {
    stdout.writeln('SQL_CHECK_EVENT {"error":"Embedded PostgreSQL could not start or attach. Check its cache, version and running instance."}');
    exitCode = 1;
  } finally {
    if (owned && pg != null) await pg.stop();
    await iterator.cancel();
  }
}
''';

String migrationHelper({required String protocol, required String endpoints}) =>
    '''
import 'dart:convert';
import 'dart:io';
import 'package:serverpod/serverpod.dart' as sp;
import 'package:serverpod_shared/serverpod_shared.dart' as shared;
import '$protocol' as generated;
import '$endpoints' as generated_endpoints;

Future<void> main() async {
  final input = await stdin.transform(utf8.decoder).join();
  final target = jsonDecode(input) as Map;
  // Fully supplied config prevents inherited SERVERPOD_* variables from
  // redirecting migrations to the project's ordinary database.
  final config = sp.ServerpodConfig(
    apiServer: sp.ServerConfig(port: 0, publicScheme: 'http',
      publicHost: 'localhost', publicPort: 0),
    runMode: 'development',
    role: shared.ServerpodRole.maintenance,
    applyMigrations: true,
    applyRepairMigration: false,
    futureCallExecutionEnabled: false,
    database: sp.DatabaseConfig(
      host: target['host'] as String,
      port: target['port'] as int,
      name: target['database'] as String,
      user: target['user'] as String,
      password: target['password'] as String,
      isUnixSocket: target['unix'] as bool,
      searchPaths: searchPaths(target['searchPath'] as String?),
    ),
  );
  final pod = sp.Serverpod(
    ['--mode', 'development', '--role', 'maintenance', '--apply-migrations'],
    generated.Protocol(), generated_endpoints.Endpoints(), config: config,
  );
  // Development mode makes integrity failures fatal in both 3.4 and 4.x.
  try {
    await pod.start(runInGuardedZone: false);
  } on sp.ExitException catch (error) {
    exitCode = error.exitCode;
  } catch (_) {
    stderr.writeln('Migration or integrity verification failed.');
    exitCode = 1;
  } finally {
    await pod.shutdown(exitProcess: false);
  }
}

List<String>? searchPaths(String? value) {
  if (value == null) return null;
  final result = <String>[];
  final part = StringBuffer();
  var quoted = false;
  var identifierQuoted = false;
  void finish() {
    final name = identifierQuoted ? part.toString() : part.toString().trim()
        .replaceAllMapped(RegExp('[A-Z]'), (match) => match[0]!.toLowerCase());
    result.add(name); part.clear(); identifierQuoted = false;
  }
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (char == '"') {
      if (quoted && index + 1 < value.length && value[index + 1] == '"') {
        part.write('"'); index++;
      } else {
        if (!quoted) {
          if (part.toString().trim().isEmpty) part.clear();
          identifierQuoted = true;
        }
        quoted = !quoted;
      }
    } else if (char == ',' && !quoted) {
      finish();
    } else if (quoted || !identifierQuoted || char.trim().isNotEmpty) {
      part.write(char);
    }
  }
  if (quoted) throw const FormatException('Unterminated search path identifier');
  finish();
  return result;
}
''';
