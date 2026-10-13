import 'dart:io';

import 'package:serverpod_sql_check/serverpod_sql_check.dart';

/// Run from the package directory with `dart run example/main.dart`.
Future<void> main() async {
  // Resolve the sample beside this script, regardless of the working directory.
  final queryFile = File.fromUri(Platform.script.resolve('query.sql'));

  // Check SQL syntax and PL/pgSQL bodies without executing any statements
  // or connecting to a database. Diagnostics and a summary go to the console;
  // This sample includes intentionally invalid syntax and exits with code 1.
  // Fix the invalid SELECT in query.sql to reveal the PL/pgSQL error next.
  await checkSql([queryFile.path, '--verbose']);
}
