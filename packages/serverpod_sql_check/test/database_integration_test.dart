import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';
import 'package:postgresql_parser/postgresql_parser.dart';
import 'package:serverpod_sql_check/src/database_check.dart';
import 'package:test/test.dart';

/// This URL must point to a disposable database: fixtures create and drop a
/// uniquely named schema and role, separate from the CLI's read-only session.
void main() {
  final adminUrl = Platform.environment['SQL_CHECK_TEST_DATABASE_URL'];
  if (adminUrl == null || adminUrl.isEmpty) {
    test(
      'database integration requires SQL_CHECK_TEST_DATABASE_URL',
      () {},
      skip: 'Provide a disposable PostgreSQL 16/17/18 test database.',
    );
    return;
  }

  late Connection admin;
  late Directory bundle;
  late Directory fixture;
  late String executable;
  late String databaseUrl;
  late int major;
  final suffix = '${pid}_${DateTime.now().microsecondsSinceEpoch}';
  final schema = 'sqlcheck_$suffix';
  final role = 'sqlrole_$suffix';
  const password = 'disposable_checker_fixture';

  Future<Result> execute(String sql) => admin.execute(sql);

  setUpAll(() async {
    admin = await Connection.openFromUrl(adminUrl);
    major =
        ((await execute("SELECT current_setting('server_version_num')::int"))
                .single[0]
            as int) ~/
        10000;
    expect([16, 17, 18], contains(major));
    await execute('CREATE SCHEMA $schema');
    await execute("CREATE ROLE $role LOGIN PASSWORD '$password'");
    await execute(
      'CREATE TABLE $schema.products(id int PRIMARY KEY, label text NOT NULL, amount int DEFAULT 0)',
    );
    await execute(
      'CREATE TABLE $schema.source(id int PRIMARY KEY, label text NOT NULL)',
    );
    await execute(
      'CREATE FUNCTION $schema.fail_if_called() RETURNS int LANGUAGE plpgsql AS '
      r"$$ BEGIN RAISE EXCEPTION 'checker executed a function'; END; $$",
    );
    await execute('GRANT USAGE ON SCHEMA $schema TO $role');
    await execute(
      'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $schema TO $role',
    );
    await execute('ALTER ROLE $role SET search_path TO $schema, public');
    final uri = Uri.parse(adminUrl);
    final params = Map<String, String>.from(uri.queryParameters)
      ..remove('user')
      ..remove('username')
      ..remove('password');
    databaseUrl = uri
        .replace(userInfo: '$role:$password', queryParameters: params)
        .toString();
    bundle = Directory.systemTemp.createTempSync('database_check_cli_');
    executable = p.join(bundle.path, 'bundle', 'bin', 'serverpod_sql_check');
    final build = await Process.run(Platform.resolvedExecutable, [
      'build',
      'cli',
      '--target=bin/serverpod_sql_check.dart',
      '--output=${bundle.path}',
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
  });

  tearDownAll(() async {
    await execute('DROP SCHEMA $schema CASCADE');
    await execute('DROP ROLE $role');
    await admin.close();
    bundle.deleteSync(recursive: true);
  });

  setUp(() async {
    fixture = Directory.systemTemp.createTempSync('database_check_source_');
    await execute('TRUNCATE $schema.products, $schema.source');
    await execute("INSERT INTO $schema.products VALUES (1, 'original', 0)");
    await execute(
      "INSERT INTO $schema.source VALUES (1, 'updated'), (2, 'new')",
    );
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  Future<ProcessResult> run(
    String source, {
    String file = 'query.sql',
    List<String> args = const [],
    String? url,
    bool connected = true,
  }) async {
    File(p.join(fixture.path, file)).writeAsStringSync(source);
    return Process.run(
      executable,
      ['--root=${fixture.path}', if (connected) '--database-check', ...args],
      environment: {
        ...Platform.environment,
        'SQL_CHECK_DATABASE_URL': url ?? databaseUrl,
      },
    );
  }

  void succeeds(ProcessResult result) =>
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

  test(
    'detects server version and inherits the application role search_path',
    () async {
      final result = await run('SELECT label FROM products;');
      succeeds(result);
      expect(result.stdout, contains('PostgreSQL $major grammar'));
      expect(
        result.stdout,
        contains('role $role; search_path $schema, public'),
      );
      expect(
        result.stdout,
        contains('Checked 1 database statements; 0 failed; 0 not covered.'),
      );
      expect(result.stdout, isNot(contains(password)));
      expect(result.stdout, isNot(contains(databaseUrl)));
    },
  );

  test(
    'finds absent relations, renamed columns, functions and incompatible types',
    () async {
      final result = await run('''SELECT label FROM absent;
      SELECT name FROM products;
      SELECT unknown_function(id) FROM products;
      SELECT label + amount FROM products;
      SELECT label FROM products;''');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('[42P01]'));
      expect(result.stderr, contains('[42703]'));
      expect(result.stderr, contains('[42883]'));
      expect(
        result.stdout,
        contains('Checked 1 database statements; 4 failed;'),
      );
      expect(result.stdout, contains('Checked 1 SQL variants; 0 failed;'));
    },
  );

  test(
    'analyzes writes, writable CTEs and functions without changing data',
    () async {
      final result = await run(
        '''INSERT INTO products VALUES (3, 'inserted', 1);
      UPDATE products SET label = 'changed';
      DELETE FROM products;
      MERGE INTO products p USING source s ON p.id = s.id
        WHEN MATCHED THEN UPDATE SET label = s.label
        WHEN NOT MATCHED THEN INSERT (id, label) VALUES (s.id, s.label);
      WITH changed AS (DELETE FROM products RETURNING *) SELECT * FROM changed;
      SELECT fail_if_called(); VALUES (1);''',
      );
      succeeds(result);
      expect(
        result.stdout,
        contains('Checked 7 database statements; 0 failed;'),
      );
      final rows = await execute(
        'SELECT id, label, amount FROM $schema.products',
      );
      expect(rows.map((row) => row.toList()).toList(), [
        [1, 'original', 0],
      ]);
    },
  );

  test('DDL, DO, CALL, COPY and SELECT INTO remain syntax-only', () async {
    final result = await run('''CREATE TABLE $schema.forbidden (id int);
      DO \$\$ BEGIN RAISE EXCEPTION 'DO executed'; END; \$\$;
      CALL absent_procedure(); COPY products TO STDOUT;
      SELECT * INTO $schema.forbidden FROM products;
      SELECT label FROM products;''');
    succeeds(result);
    expect(
      result.stdout,
      contains('Checked 1 database statements; 0 failed; 5 not covered.'),
    );
    expect(
      (await execute("SELECT to_regclass('$schema.forbidden')")).single[0],
      isNull,
    );
  });

  test(
    'named placeholders infer types and preserve repeated parameters',
    () async {
      final result = await run(r'''
void query(dynamic session) {
  session.db.unsafeQuery("SELECT label FROM products WHERE id = @id OR id = @id",
      parameters: QueryParameters.named({'id': loadId()}));
  session.db.unsafeQuery(r"SELECT $1::int");
}
''', file: 'endpoint.dart');
      succeeds(result);
      expect(
        result.stdout,
        contains('Checked 2 database statements; 0 failed; 0 not covered.'),
      );
      expect(
        result.stdout,
        contains('Checked 1 named parameter sets; 0 missing bindings;'),
      );
    },
  );

  test(
    'unknown parameter types and mixed conventions are explicitly uncovered',
    () async {
      final result = await run(
        r'''
void query(dynamic session) {
  session.db.unsafeQuery('SELECT @id IS NULL', parameters: QueryParameters.named({'id': 1}));
  session.db.unsafeQuery(r'SELECT @id::int, $1::int', parameters: QueryParameters.named({'id': 1}));
}
''',
        file: 'endpoint.dart',
        args: ['--verbose'],
      );
      succeeds(result);
      expect(
        result.stdout,
        contains('Checked 0 database statements; 0 failed; 2 not covered.'),
      );
      expect(result.stdout, contains('[42P18]'));
      expect(result.stdout, contains('mixed named and positional parameters'));
      expect(result.stdout, contains('1 unique preparations'));
    },
  );

  test(
    'only raw calls and files receive schema checks, with duplicate caching',
    () async {
      final result = await run('''
const unused = 'SELECT absent FROM missing';
const query = 'SELECT label FROM products';
void call(dynamic session) {
  session.db.unsafeQuery(query);
  session.db.unsafeQuery(query);
}
''', file: 'endpoint.dart');
      succeeds(result);
      expect(
        result.stdout,
        contains('Checked 2 database statements; 0 failed;'),
      );
      expect(result.stdout, contains('1 unique preparations'));
    },
  );

  test(
    'runtime calls are uncovered and raw calls reject multiple statements',
    () async {
      final result = await run('''
void call(dynamic session, String sql) {
  session.db.unsafeQuery(sql);
  session.db.unsafeQuery('SELECT 1; SELECT 2;');
}
''', file: 'endpoint.dart');
      expect(result.exitCode, 1);
      expect(
        result.stdout,
        contains('Checked 0 database statements; 1 failed; 1 not covered.'),
      );
      expect(result.stderr, contains('must contain a single SQL statement'));
      expect(result.stdout, contains('0 unique preparations'));
    },
  );

  test(
    'unparameterized execute batches are analyzed without executing effects',
    () async {
      // The same driver path used by Serverpod really accepts a batch when
      // ignoring rows without binding parameters.
      await admin.execute(
        'CREATE TEMP TABLE batch_probe(id int); DROP TABLE batch_probe;',
        ignoreRows: true,
      );
      final result = await run(r"""
void call(dynamic session) {
  session.db.unsafeExecute(r'''
    CREATE TABLE must_not_be_created(id int);
    DO $body$ BEGIN RAISE EXCEPTION 'must not execute'; END; $body$;
    INSERT INTO products VALUES (99, 'must not insert', 1);
    UPDATE products SET label = 'must not update';
    SELECT label FROM products;
  ''');
}
""", file: 'endpoint.dart');
      succeeds(result);
      expect(
        result.stdout,
        contains('Checked 3 database statements; 0 failed; 2 not covered.'),
      );
      expect(
        (await execute('SELECT label FROM $schema.products')).single.single,
        'original',
      );
      expect(
        (await execute("SELECT to_regclass('$schema.must_not_be_created')"))
            .single
            .single,
        isNull,
      );
    },
  );

  test(
    'parameterized execute batches still reject multiple statements',
    () async {
      final result = await run('''
void call(dynamic session) {
  session.db.unsafeExecute('SELECT @id::int; SELECT 2;',
    parameters: QueryParameters.named({'id': 1}));
}
''', file: 'endpoint.dart');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('must contain a single SQL statement'));
      expect(result.stdout, contains('0 unique preparations'));
    },
  );

  test(
    'Unicode script and named parameter errors point at original source',
    () async {
      const source = '''
void call(dynamic session) {
  session.db.unsafeQuery("SELECT '😀', @long_parameter::int, absent FROM products",
    parameters: QueryParameters.named({'long_parameter': 1}));
}
''';
      final result = await run(source, file: 'endpoint.dart');
      expect(result.exitCode, 1);
      final lines = source.split('\n');
      final lineIndex = lines.indexWhere((line) => line.contains('absent'));
      final line = lines[lineIndex];
      final column = line.substring(0, line.indexOf('absent')).runes.length + 1;
      expect(
        result.stderr,
        contains(
          'FAIL endpoint.dart:${lineIndex + 1}:$column: DATABASE [42703]',
        ),
      );
      expect(result.stderr, contains('column "absent" does not exist'));
    },
  );

  test(
    'Unicode statement slicing and quoting keep semicolons inside literals',
    () async {
      final result = await run(
        "SELECT '😀; café'; SELECT \$custom\$;😀\$custom\$; SELECT label FROM products;",
      );
      succeeds(result);
      expect(
        result.stdout,
        contains('Checked 3 database statements; 0 failed;'),
      );
    },
  );

  test(
    'Unicode before a later script error preserves its line and column',
    () async {
      final result = await run("SELECT '😀';\nSELECT absent FROM products;");
      expect(result.exitCode, 1);
      expect(result.stderr, contains('FAIL query.sql:2:8: DATABASE [42703]'));
    },
  );

  test('cached failures retain each named parameter source location', () async {
    const source = '''
void call(dynamic session) {
  session.db.unsafeQuery('SELECT @long_parameter::int, absent FROM products', parameters: QueryParameters.named({'long_parameter': 1}));
  session.db.unsafeQuery('SELECT @x::int, absent FROM products', parameters: QueryParameters.named({'x': 1}));
}
''';
    final result = await run(source, file: 'endpoint.dart');
    expect(result.exitCode, 1);
    expect(result.stdout, contains('Checked 0 database statements; 2 failed;'));
    expect(result.stdout, contains('1 unique preparations'));
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains('absent')) continue;
      final column = lines[i].indexOf('absent') + 1;
      expect(
        result.stderr,
        contains('FAIL endpoint.dart:${i + 1}:$column: DATABASE [42703]'),
      );
    }
  });

  test('syntax failures never reach PREPARE', () async {
    final result = await run('SELECT FROM;');
    expect(result.exitCode, 1);
    expect(
      result.stdout,
      contains('Checked 0 database statements; 0 failed; 1 not covered.'),
    );
    expect(result.stdout, contains('0 unique preparations'));
  });

  test(
    'search_path override is parameterized and does not execute injected SQL',
    () async {
      final missing = await run(
        'SELECT label FROM products;',
        args: ['--database-search-path=public'],
      );
      expect(missing.exitCode, 1);
      File(p.join(fixture.path, 'query.sql')).deleteSync();
      final qualified = await run(
        'SELECT label FROM products;',
        args: ['--database-search-path=$schema'],
      );
      succeeds(qualified);
      File(p.join(fixture.path, 'query.sql')).deleteSync();
      final injection = await run(
        'SELECT 1;',
        args: ['--database-search-path=public; DROP TABLE $schema.products'],
      );
      expect(injection.exitCode, 2);
      expect(
        (await execute('SELECT count(*) FROM $schema.products')).single[0],
        1,
      );
    },
  );

  test('explicit parser mismatch fails before scanning', () async {
    final result = await run(
      'SELECT 1;',
      args: ['--postgres-version=${major == 17 ? 18 : 17}'],
    );
    expect(result.exitCode, 2);
    expect(
      result.stderr,
      contains('does not match database PostgreSQL $major'),
    );
    expect(result.stdout, isNot(contains('Scanned')));
  });

  test(
    'connection failures never disclose URL, password or username',
    () async {
      // Loopback connections can use trust authentication in test containers.
      // A nonexistent role fails independently of the pg_hba password policy.
      final unknownRole = 'private_missing_role_$suffix';
      final wrong = Uri.parse(databaseUrl)
          .replace(userInfo: '$unknownRole:secret_invalid_password')
          .toString();
      final result = await run('SELECT 1;', url: wrong);
      expect(result.exitCode, 2);
      final output = '${result.stdout}\n${result.stderr}';
      expect(output, isNot(contains(wrong)));
      expect(output, isNot(contains('secret_invalid_password')));
      expect(output, isNot(contains(role)));
      expect(output, isNot(contains(unknownRole)));
      expect(
        output,
        contains('Could not configure the test database connection'),
      );
    },
  );

  test(
    'successes and failures leave no SQL prepared statements behind',
    () async {
      final connection = await Connection.openFromUrl(databaseUrl);
      final checker = await DatabaseChecker.configure(connection);
      final parser = PostgresParser(
        version: PostgresParser.supportedVersions.singleWhere(
          (v) => v.major == major,
        ),
      );
      try {
        DatabaseStatement statement(String sql) =>
            databaseStatements(parser.parse(sql), sql).single;
        for (var i = 0; i < 5; i++) {
          expect(
            (await checker.check(
              statement('SELECT label FROM products WHERE id = $i'),
            )).status,
            DatabaseCheckStatus.checked,
          );
          expect(
            (await checker.check(statement('SELECT missing_$i FROM products')))
                .status,
            DatabaseCheckStatus.failed,
          );
        }
        final pending = await connection.execute(
          "SELECT name FROM pg_prepared_statements WHERE name LIKE 'serverpod_sql_check_%'",
        );
        expect(pending, isEmpty);
        final mode = await connection.execute(
          "SHOW default_transaction_read_only",
        );
        expect(mode.single[0], 'on');
        expect(checker.preparations, 10);
        expect(checker.stopped, isFalse);
      } finally {
        await checker.close();
      }
    },
  );

  test(
    'lost connections interrupt validation without leaking driver errors',
    () async {
      final connection = await Connection.openFromUrl(databaseUrl);
      final backend =
          (await connection.execute('SELECT pg_backend_pid()')).single[0]
              as int;
      final checker = await DatabaseChecker.configure(connection);
      try {
        await execute('SELECT pg_terminate_backend($backend)');
        await expectLater(
          checker.check(const DatabaseStatement('SELECT 1', 0, 8, null)),
          throwsA(
            isA<DatabaseCheckException>().having(
              (e) => e.message,
              'message',
              contains('lost connection'),
            ),
          ),
        );
        expect(checker.stopped, isTrue);
      } finally {
        await checker.close();
      }
    },
  );

  test(
    'query timeout interrupts database validation and preserves later coverage',
    () async {
      await execute('BEGIN');
      await execute('LOCK TABLE $schema.products IN ACCESS EXCLUSIVE MODE');
      try {
        final result = await run(
          'SELECT label FROM products; SELECT label FROM products;',
          args: ['--verbose'],
        );
        expect(result.exitCode, 2);
        expect(
          result.stdout,
          contains('Checked 0 database statements; 0 failed; 2 not covered.'),
        );
        expect(result.stdout, contains('; incomplete'));
        expect(result.stderr, contains('timeout or lost connection'));
      } finally {
        await execute('ROLLBACK');
      }
    },
  );

  test('reports added database time and preserves offline results', () async {
    const sql = 'SELECT label FROM products; SELECT label FROM products;';
    final offline = await run(sql, connected: false);
    succeeds(offline);
    final connected = await run(sql);
    succeeds(connected);
    expect(offline.stdout, contains('Checked 1 SQL variants; 0 failed;'));
    expect(connected.stdout, contains('Checked 1 SQL variants; 0 failed;'));
    expect(connected.stdout, matches(RegExp(r'Database validation: \d+ ms;')));
  });
}
