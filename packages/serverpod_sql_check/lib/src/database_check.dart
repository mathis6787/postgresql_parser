/// Schema checks for an explicitly supplied, preconfigured test database.
library;

import 'dart:async';
import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:postgresql_parser/postgresql_parser.dart';

enum DatabaseCheckStatus { checked, failed, uncovered }

final class DatabaseCheckResult {
  const DatabaseCheckResult(
    this.status, {
    this.message,
    this.code,
    this.offset,
  });
  final DatabaseCheckStatus status;
  final String? message;
  final String? code;

  /// UTF-16 offset within the statement, excluding the PREPARE prefix.
  final int? offset;
}

final class DatabaseCheckException implements Exception {
  const DatabaseCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class DatabaseStatement {
  const DatabaseStatement(
    this.sql,
    this.start,
    this.end,
    this.unsupportedReason,
  );
  final String sql;
  final int start;
  final int end;
  final String? unsupportedReason;
}

/// Locations in libpg_query are UTF-8 bytes; callers use UTF-16 source maps.
List<DatabaseStatement> databaseStatements(ParseResult parsed, String sql) {
  final bytes = const Utf8Encoder().convert(sql);
  final statements = <DatabaseStatement>[];
  for (final raw in parsed.tree['stmts'] as List) {
    final statement = raw as Map;
    final node = statement['stmt'] as Map;
    final byteStart = statement['stmt_location'] as int? ?? 0;
    final byteLength = statement['stmt_len'] as int? ?? 0;
    final start = const Utf8Decoder()
        .convert(bytes.sublist(0, byteStart))
        .length;
    final end = byteLength == 0
        ? sql.length
        : start +
              const Utf8Decoder()
                  .convert(bytes.sublist(byteStart, byteStart + byteLength))
                  .length;
    final kind = node.keys.single as String;
    final supported = const {
      'SelectStmt',
      'InsertStmt',
      'UpdateStmt',
      'DeleteStmt',
      'MergeStmt',
    }.contains(kind);
    final selectInto =
        kind == 'SelectStmt' && (node[kind] as Map)['intoClause'] != null;
    final label =
        const {
          'CreateStmt': 'CREATE TABLE',
          'CreateFunctionStmt': 'CREATE FUNCTION/PROCEDURE',
          'DoStmt': 'DO',
          'CallStmt': 'CALL',
          'CopyStmt': 'COPY',
          'VariableSetStmt': 'SET/RESET',
          'TransactionStmt': 'transaction control',
          'AlterTableStmt': 'ALTER TABLE',
          'DropStmt': 'DROP',
          'ExplainStmt': 'EXPLAIN',
          'VacuumStmt': 'VACUUM/ANALYZE',
        }[kind] ??
        'this statement';
    statements.add(
      DatabaseStatement(
        sql.substring(start, end),
        start,
        end,
        selectInto
            ? 'SELECT INTO is not supported by PREPARE'
            : supported
            ? null
            : '$label is syntax-only; not supported by PREPARE',
      ),
    );
  }
  return statements;
}

/// Does not execute SQL from the scanned source. Only PREPARE wrappers are sent.
final class DatabaseChecker {
  DatabaseChecker._(this._connection, this._secrets, this.elapsed);
  final Connection _connection;
  final List<String> _secrets;
  final Duration _queryTimeout = const Duration(seconds: 5);
  Duration elapsed;
  late final int major;
  late final String serverVersion;
  late final String role;
  late final String searchPath;
  bool stopped = false;
  int preparations = 0;
  final _cache = <String, DatabaseCheckResult>{};

  static Future<DatabaseChecker> open(String url, {String? searchPath}) async {
    final watch = Stopwatch()..start();
    Connection? connection;
    try {
      final uri = Uri.parse(url);
      if (!{'postgres', 'postgresql'}.contains(uri.scheme) ||
          uri.fragment.isNotEmpty) {
        throw const DatabaseCheckException(
          'Invalid PostgreSQL connection URL.',
        );
      }
      final params = uri.queryParameters;
      final userInfo = uri.userInfo.split(':');
      final secrets = [
        url,
        if (userInfo.isNotEmpty && userInfo.first.isNotEmpty)
          Uri.decodeComponent(userInfo.first),
        if (userInfo.length > 1)
          Uri.decodeComponent(userInfo.sublist(1).join(':')),
        if (params['password'] case final String password) password,
        if (params['user'] case final String user) user,
        if (params['username'] case final String user) user,
      ].where((value) => value.isNotEmpty).toList();
      // Enforce the CLI limits and UTF-8 source mapping; honor SSL settings.
      final configured = uri.replace(
        queryParameters: {
          ...params,
          'connect_timeout': '10',
          'query_timeout': '5',
          'client_encoding': 'UTF8',
          'replication': 'false',
          'application_name': 'serverpod_sql_check',
        },
      );
      var abandoned = false;
      final opening = Connection.openFromUrl(configured.toString());
      unawaited(
        opening
            .then((value) async {
              if (abandoned) await value.close(force: true);
            })
            .catchError((Object _) {}),
      );
      connection = await opening.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          abandoned = true;
          throw TimeoutException('Connection timeout');
        },
      );
      final checker = await configure(
        connection,
        searchPath: searchPath,
        secrets: secrets,
      );
      checker.elapsed = watch.elapsed;
      return checker;
    } catch (_) {
      // Driver and server connection errors can contain passwords or usernames.
      if (connection != null) {
        try {
          await connection.close(force: true);
        } catch (_) {
          /* Preserve the sanitized error. */
        }
      }
      throw const DatabaseCheckException(
        'Could not configure the test database connection. Check the URL, credentials, SSL settings and server availability.',
      );
    }
  }

  /// Takes ownership of an already open session. Used by the CLI connection
  /// factory and integration tests that inspect the same session's resources.
  static Future<DatabaseChecker> configure(
    Connection connection, {
    String? searchPath,
    List<String> secrets = const [],
  }) async {
    final checker = DatabaseChecker._(connection, secrets, Duration.zero);
    await checker._execute(
      'SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY',
    );
    await checker._execute("SET standard_conforming_strings = on");
    await checker._execute("SET statement_timeout = '5s'");
    if (searchPath != null) {
      await checker._execute(
        r"SELECT pg_catalog.set_config('search_path', $1, false)",
        parameters: [searchPath],
      );
    }
    final info = await checker._execute(
      "SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4, "
      "pg_catalog.current_setting('server_version'), current_user, pg_catalog.current_setting('search_path')",
    );
    checker.major = (info.single[0] as int) ~/ 10000;
    checker.serverVersion = info.single[1] as String;
    checker.role = info.single[2] as String;
    checker.searchPath = info.single[3] as String;
    return checker;
  }

  Future<Result> _execute(String sql, {List<Object?>? parameters}) async {
    final watch = Stopwatch()..start();
    try {
      // Extended protocol forbids multiple top-level commands, even in PREPARE.
      return await _connection
          .execute(
            Sql(sql),
            parameters: parameters,
            queryMode: QueryMode.extended,
            timeout: _queryTimeout,
          )
          .timeout(_queryTimeout);
    } finally {
      elapsed += watch.elapsed;
    }
  }

  String _redact(String message) {
    for (final secret in _secrets) {
      message = message.replaceAll(secret, '<redacted>');
    }
    return message;
  }

  Future<DatabaseCheckResult> check(DatabaseStatement statement) async {
    if (statement.unsupportedReason case final String reason) {
      return DatabaseCheckResult(
        DatabaseCheckStatus.uncovered,
        message: reason,
      );
    }
    if (stopped) {
      return const DatabaseCheckResult(
        DatabaseCheckStatus.uncovered,
        message: 'database validation interrupted',
      );
    }
    if (_cache[statement.sql] case final DatabaseCheckResult cached) {
      return cached;
    }
    final name = 'serverpod_sql_check_${preparations++}';
    final prefix = 'PREPARE $name AS ';
    var prepared = false;
    DatabaseCheckResult result;
    try {
      await _execute('$prefix${statement.sql}');
      prepared = true;
      result = const DatabaseCheckResult(DatabaseCheckStatus.checked);
    } on ServerException catch (error) {
      if (error.code == '57014' ||
          error.code?.startsWith('08') == true ||
          error.code?.startsWith('57P0') == true ||
          error.severity == Severity.fatal ||
          error.severity == Severity.panic) {
        return await _interrupt(
          'Database validation interrupted by a timeout or lost connection.',
        );
      }
      final position = error.position;
      final characterOffset = position == null
          ? null
          : position - 1 - prefix.runes.length;
      final offset =
          characterOffset != null &&
              characterOffset >= 0 &&
              characterOffset <= statement.sql.runes.length
          ? String.fromCharCodes(statement.sql.runes.take(characterOffset))
                .length
          : null;
      result = DatabaseCheckResult(
        error.code == '42P18' || error.code == '42P08'
            ? DatabaseCheckStatus.uncovered
            : DatabaseCheckStatus.failed,
        message: _redact(error.message),
        code: error.code,
        offset: offset,
      );
    } catch (_) {
      return await _interrupt(
        'Database validation interrupted by a timeout or lost connection.',
      );
    } finally {
      if (prepared) {
        try {
          await _execute('DEALLOCATE $name');
        } catch (_) {
          await _interrupt(
            'Database validation interrupted while releasing a prepared statement.',
          );
        }
      }
    }
    _cache[statement.sql] = result;
    return result;
  }

  Future<void> close() async {
    await _connection.close(force: true);
  }

  Future<Never> _interrupt(String message) async {
    stopped = true;
    try {
      await close();
    } catch (_) {
      // The session may already be closed by the driver.
    }
    throw DatabaseCheckException(message);
  }
}
