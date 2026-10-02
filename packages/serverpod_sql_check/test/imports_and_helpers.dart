import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Reuses the discovery suite's native bundle to exercise the actual CLI.
void importedSqlAndHelperTests(
  Directory Function() fixture,
  Future<ProcessResult> Function(Directory, List<String>) run,
) {
  File write(String path, String source) {
    final file = File(p.join(fixture().path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
    return file;
  }

  Future<ProcessResult> check(String source, {int major = 17}) {
    final file = write('endpoint.dart', source);
    return run(fixture(), [
      '--root=${fixture().path}',
      '--verbose',
      '--postgres-version=$major',
      file.path,
    ]);
  }

  void expectChecked(ProcessResult result, {int count = 1, int failures = 0}) {
    expect(
      result.exitCode,
      failures == 0 ? 0 : 1,
      reason: '${result.stdout}\n${result.stderr}',
    );
    expect(
      result.stdout,
      contains('Checked $count SQL variants; $failures failed; 0 dynamic'),
    );
  }

  void expectSkipped(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 0 SQL variants; 0 failed; 1 dynamic'),
    );
    expect(result.stdout, contains('SKIP endpoint.dart:'));
  }

  const directCall =
      'void example(dynamic session) { session.db.unsafeQuery(equipmentSql); }';
  const constant = "const equipmentSql = 'select 1';";

  group('imported SQL', () {
    for (final entry in <String, String>{
      'relative': "import 'lib/queries.dart';\n$directCall",
      'prefix': "import 'lib/queries.dart' as queries;\nvoid example(dynamic session) { session.db.unsafeQuery(queries.equipmentSql); }",
      'show': "import 'lib/queries.dart' show equipmentSql;\n$directCall",
      'hide unrelated': "import 'lib/queries.dart' hide unused;\n$directCall",
      'alias shadowed by another import': "import 'lib/queries.dart' as queries;\nimport 'lib/other.dart';\nvoid example(dynamic session) { session.db.unsafeQuery(queries.equipmentSql); }",
    }.entries) {
      test(entry.key, () async {
        write('lib/queries.dart', constant);
        write('lib/other.dart', "const queries = 'unrelated';");
        expectChecked(await check(entry.value));
      });
    }

    test(
      'final initializer follows imported fragments and interpolation',
      () async {
        write('lib/fragment.dart', "const clause = 'where id = @id';");
        write(
          'lib/queries.dart',
          "import 'fragment.dart';\nfinal equipmentSql = 'select * from equipment ' + clause;",
        );
        expectChecked(
          await check(
            "import 'lib/queries.dart';\nvoid example(dynamic session) { session.db.unsafeQuery(equipmentSql, parameters: QueryParameters.named({'id': 1})); }",
          ),
        );
      },
    );

    test('re-exports preserve prefixes and show/hide rules', () async {
      write('lib/queries.dart', constant);
      write('lib/barrel.dart', "export 'queries.dart' show equipmentSql;");
      write('lib/public.dart', "export 'barrel.dart' hide unused;");
      expectChecked(
        await check(
          "import 'lib/public.dart' as q;\nvoid example(dynamic session) { session.db.unsafeQuery(q.equipmentSql); }",
        ),
      );
    });

    test(
      'imports work inside subclasses when the base hierarchy is readable',
      () async {
        write('lib/base.dart', 'class Base {} class Middle extends Base {}');
        write('lib/queries.dart', constant);
        expectChecked(
          await check(
            "import 'lib/base.dart'; import 'lib/queries.dart';\nclass Example extends Middle { void run(dynamic session) { session.db.unsafeQuery(equipmentSql); } }",
          ),
        );
        expectChecked(
          await check(
            "import 'lib/base.dart'; import 'lib/queries.dart' as q;\nclass Example extends Middle { void run(dynamic session) { session.db.unsafeQuery(q.equipmentSql); } }",
          ),
        );
      },
    );

    for (final inheritance in ['extends', 'implements']) {
      test('$inheritance members can hide an imported SQL name', () async {
        write(
          'lib/base.dart',
          'abstract class Base { String get equipmentSql; }',
        );
        write('lib/queries.dart', constant);
        expectSkipped(
          await check(
            "import 'lib/base.dart'; import 'lib/queries.dart';\nabstract class Example $inheritance Base { void run(dynamic session) { session.db.unsafeQuery(equipmentSql); } }",
          ),
        );
      });
    }

    test('mixin members can hide an import prefix', () async {
      write('lib/base.dart', 'mixin Base { dynamic get q; }');
      write('lib/queries.dart', constant);
      expectSkipped(
        await check(
          "import 'lib/base.dart'; import 'lib/queries.dart' as q;\nclass Example with Base { void run(dynamic session) { session.db.unsafeQuery(q.equipmentSql); } }",
        ),
      );
    });

    test('unknown inherited declarations remain skipped', () async {
      write('lib/queries.dart', constant);
      expectSkipped(
        await check(
          "import 'lib/queries.dart';\nclass Example extends MissingBase { void run(dynamic session) { session.db.unsafeQuery(equipmentSql); } }",
        ),
      );
    });

    test(
      're-export cycles terminate and duplicate paths to one declaration agree',
      () async {
        write('lib/queries.dart', constant);
        write('lib/a.dart', "export 'b.dart'; export 'queries.dart';");
        write('lib/b.dart', "export 'a.dart'; export 'queries.dart';");
        expectChecked(
          await check("import 'lib/a.dart'; import 'lib/b.dart';\n$directCall"),
        );
      },
    );

    for (final absolute in [false, true]) {
      test(
        'package imports with ${absolute ? 'absolute' : 'relative'} directory URIs',
        () async {
          write('lib/queries.dart', constant);
          write(
            '.dart_tool/package_config.json',
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'fixture',
                  'rootUri': absolute
                      ? Uri.directory(fixture().path)
                            .toString()
                            .replaceFirst(RegExp(r'/$'), '')
                      : '..',
                  'packageUri': 'lib',
                  'languageVersion': '3.13',
                },
              ],
            }),
          );
          expectChecked(
            await check(
              "import 'package:fixture/queries.dart' as q;\nvoid example(dynamic session) { session.db.unsafeQuery(q.equipmentSql); }",
            ),
          );
        },
      );
    }

    test(
      'dependencies reuse the importing project package configuration',
      () async {
        write(
          'deps/first/lib/queries.dart',
          "import 'package:second/fragment.dart';\nconst equipmentSql = fragment;",
        );
        write('deps/second/lib/fragment.dart', "const fragment = 'select 1';");
        write(
          '.dart_tool/package_config.json',
          jsonEncode({
            'configVersion': 2,
            'packages': [
              for (final name in ['first', 'second'])
                {
                  'name': name,
                  'rootUri': '../deps/$name',
                  'packageUri': 'lib/',
                },
            ],
          }),
        );
        expectChecked(
          await check("import 'package:first/queries.dart';\n$directCall"),
        );
      },
    );

    test(
      'Unicode paths and SQL retain their original error location',
      () async {
        // A literal Dart Unicode escape exercises decoding and cross-file offsets.
        final actual =
            "// café 😀\n" + r"const equipmentSql = 'select \u0066rom;';";
        write('lib/café_queries.dart', actual);
        final result = await check(
          "import 'lib/café_queries.dart';\n$directCall",
        );
        expectChecked(result, failures: 1);
        expect(result.stderr, contains('FAIL lib/café_queries.dart:2:'));
        expect(result.stderr, contains(actual.split('\n')[1]));
      },
    );

    test('syntax errors point to the originating fragment after parameter rewriting', () async {
      write(
        'lib/first.dart',
        r"const start = 'select @long_parameter_name::int ';",
      );
      write('lib/second.dart', "const end = 'from;';");
      write(
        'lib/queries.dart',
        "import 'first.dart'; import 'second.dart';\nconst equipmentSql = start + end;",
      );
      final result = await check(
        "import 'lib/queries.dart';\nvoid example(dynamic session) { session.db.unsafeQuery(equipmentSql, parameters: QueryParameters.named({'long_parameter_name': 1})); }",
      );
      expectChecked(result, failures: 1);
      expect(result.stderr, contains('FAIL lib/second.dart:1:18'));
    });

    test('missing bindings point to the imported placeholder', () async {
      write('lib/queries.dart', r"const equipmentSql = 'select @id';");
      final result = await check("import 'lib/queries.dart';\n$directCall");
      expect(result.exitCode, 1);
      expect(
        result.stdout,
        contains('Checked 1 named parameter sets; 1 missing bindings'),
      );
      expect(result.stderr, contains('FAIL lib/queries.dart:1:30'));
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });

    test('imported binding keys are resolved at the call', () async {
      write(
        'lib/queries.dart',
        r"const equipmentSql = 'select @id'; const bindingName = 'id';",
      );
      expectChecked(
        await check(
          "import 'lib/queries.dart' as q;\nvoid example(dynamic session) { session.db.unsafeQuery(q.equipmentSql, parameters: QueryParameters.named({q.bindingName: 1})); }",
        ),
      );
    });

    for (final major in [17, 18]) {
      test('imported PL/pgSQL is checked on PostgreSQL $major', () async {
        write(
          'lib/queries.dart',
          r"const equipmentSql = r'DO $$ BEGIN IF THEN END IF; END; $$;';",
        );
        final result = await check(
          "import 'lib/queries.dart';\n$directCall",
          major: major,
        );
        expectChecked(result, failures: 1);
        expect(result.stderr, contains('FAIL lib/queries.dart:1:'));
        expect(result.stderr, contains('PL/pgSQL:'));
      });
    }

    for (final entry in <String, String>{
      'hidden': "import 'lib/queries.dart' hide equipmentSql;\n$directCall",
      'not shown': "import 'lib/queries.dart' show unused;\n$directCall",
      'private': "import 'lib/queries.dart';\nvoid example(dynamic session) { session.db.unsafeQuery(_privateSql); }",
      'local shadow': "import 'lib/queries.dart';\nvoid example(dynamic session, String equipmentSql) { session.db.unsafeQuery(equipmentSql); }",
      'prefix shadow': "import 'lib/queries.dart' as q;\nvoid example(dynamic session, dynamic q) { session.db.unsafeQuery(q.equipmentSql); }",
      'missing': "import 'missing.dart';\n$directCall",
      'package without configuration':
          "import 'package:missing/queries.dart';\n$directCall",
      'conditional import':
          "import 'lib/queries.dart' if (dart.library.io) 'lib/other.dart';\n$directCall",
      'ambiguous':
          "import 'lib/queries.dart'; import 'lib/other.dart';\n$directCall",
    }.entries) {
      test('${entry.key} remains skipped', () async {
        write(
          'lib/queries.dart',
          "$constant\nconst _privateSql = 'select 1'; const unused = 'unrelated';",
        );
        write('lib/other.dart', "const equipmentSql = 'select 2';");
        expectSkipped(await check(entry.value));
      });
    }

    for (final declaration in [
      "var equipmentSql = 'select 1';",
      "late final equipmentSql = 'select 1';",
      "String get equipmentSql => loadSql(); String loadSql() => DateTime.now().toString();",
      "final equipmentSql = other; final other = equipmentSql;",
      "const equipmentSql = 'select 1'; this is invalid dart",
    ]) {
      test('unsupported imported initializer: $declaration', () async {
        write('lib/queries.dart', declaration);
        expectSkipped(await check("import 'lib/queries.dart';\n$directCall"));
      });
    }

    test('a hidden re-export remains unresolved', () async {
      write('lib/queries.dart', constant);
      write('lib/barrel.dart', "export 'queries.dart' hide equipmentSql;");
      expectSkipped(await check("import 'lib/barrel.dart';\n$directCall"));
    });

    test(
      'an ambiguous class name is not selected by matching its field',
      () async {
        write('lib/a.dart', "class Queries { static const sql = 'select 1'; }");
        write('lib/b.dart', 'class Queries {}');
        expectSkipped(
          await check(
            "import 'lib/a.dart'; import 'lib/b.dart';\nvoid example(dynamic session) { session.db.unsafeQuery(Queries.sql); }",
          ),
        );
      },
    );

    test('package configurations are isolated when two projects share source', () async {
      write(
        'shared/lib/queries.dart',
        "import 'package:fragment/queries.dart';\nconst equipmentSql = fragment;",
      );
      final entries = <String>[];
      for (final project in ['one', 'two']) {
        write(
          '$project/fragment/lib/queries.dart',
          "const fragment = '${project == 'one' ? 'select 1' : 'select from;'}';",
        );
        write(
          '$project/.dart_tool/package_config.json',
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'shared',
                'rootUri': '../../shared',
                'packageUri': 'lib/',
              },
              {
                'name': 'fragment',
                'rootUri': '../fragment',
                'packageUri': 'lib/',
              },
            ],
          }),
        );
        entries.add(
          write(
            '$project/endpoint.dart',
            "import 'package:shared/queries.dart';\n$directCall",
          ).path,
        );
      }
      final result = await run(fixture(), [
        '--root=${fixture().path}',
        '--verbose',
        ...entries,
      ]);
      expectChecked(result, count: 2, failures: 1);
      expect(result.stderr, contains('FAIL two/fragment/lib/queries.dart:'));
      expect(result.stderr, isNot(contains('FAIL one/')));
    });

    test('a conditional re-export remains unresolved', () async {
      write('lib/queries.dart', constant);
      write('lib/other.dart', constant);
      write(
        'lib/barrel.dart',
        "export 'queries.dart' if (dart.library.io) 'other.dart';",
      );
      expectSkipped(await check("import 'lib/barrel.dart';\n$directCall"));
    });
  });

  group('helper returns', () {
    final supported = <String, (String, int)>{
      'arrow': ("String buildQuery(dynamic filters) => 'select 1';", 1),
      'block': ("String buildQuery(dynamic filters) { return 'select 1'; }", 1),
      'runtime condition': (
        "String buildQuery(dynamic filters) { if (filters.onlyActive) return 'select 1'; return 'select 2'; }",
        2,
      ),
      'nested branches': (
        "String buildQuery(dynamic filters) { if (filters.a) { if (filters.b) return 'select 1'; else return 'select 2'; } else { return 'select 3'; } }",
        3,
      ),
      'immutable local': (
        "String buildQuery(dynamic filters) { final sql = filters.a ? 'select 1' : 'select 2'; return sql; }",
        2,
      ),
      'nested helpers': (
        "String fragment() => 'select 1'; String buildQuery(dynamic filters) => fragment();",
        1,
      ),
      'forward helper': (
        "String buildQuery(dynamic filters) => fragment(); String fragment() => 'select 1';",
        1,
      ),
      'known condition': (
        "String buildQuery(dynamic filters) { if (true) return 'select 1'; return filters.sql; }",
        1,
      ),
    };
    for (final entry in supported.entries) {
      test(entry.key, () async {
        expectChecked(
          await check(
            '${entry.value.$1}\nvoid example(dynamic session, dynamic filters) { session.db.unsafeQuery(buildQuery(filters)); }',
          ),
          count: entry.value.$2,
        );
      });
    }

    test('named and positional string arguments and defaults', () async {
      final result = await check(r'''
String positional([String table = 'equipment']) => 'select * from $table';
String named({String table = 'equipment'}) => 'select * from $table';
void example(dynamic session) {
  session.db.unsafeQuery(positional());
  session.db.unsafeQuery(positional('equipment'));
  session.db.unsafeQuery(named());
  session.db.unsafeQuery(named(table: 'equipment'));
}
''');
      expectChecked(result, count: 4);
    });

    test('conditional string arguments expand at the call', () async {
      expectChecked(
        await check(r'''
String build(String table) => 'select * from $table';
void example(dynamic session, bool flag) { session.db.unsafeQuery(build(flag ? 'equipment' : 'locations')); }
'''),
        count: 2,
      );
    });

    test('helpers can declare and call another local helper', () async {
      expectChecked(
        await check(
          "String buildQuery() { String fragment() => 'select 1'; return fragment(); } void example(dynamic session) { session.db.unsafeQuery(buildQuery()); }",
        ),
      );
    });

    test(
      'captured parameter mutation in a local helper stays unknown',
      () async {
        expectSkipped(
          await check(
            "String buildQuery(String sql) { bool change() { sql = 'invalid'; return true; } if (change()) return sql; return sql; } void example(dynamic session) { session.db.unsafeQuery(buildQuery('select 1')); }",
          ),
        );
      },
    );

    test('local helper declarations keep lexical scope', () async {
      expectChecked(
        await check(
          "void example(dynamic session) { String build() => 'select 1'; session.db.unsafeQuery(build()); }",
        ),
      );
    });

    test(
      'same-file static helpers and imported static fields/helpers',
      () async {
        write(
          'lib/queries.dart',
          "class Queries { static const text = 'select 1'; static String build() => text; }",
        );
        expectChecked(
          await check(
            "import 'lib/queries.dart' as q;\nclass Local { static String build() => 'select 1'; }\nvoid example(dynamic session) { session.db.unsafeQuery(Local.build()); session.db.unsafeQuery(q.Queries.text); session.db.unsafeQuery(q.Queries.build()); }",
          ),
          count: 3,
        );
      },
    );

    test(
      'imported helpers follow re-exports and private internal references',
      () async {
        write(
          'lib/helper.dart',
          "String _fragment() => 'select 1'; String buildQuery(dynamic filters) => _fragment();",
        );
        write('lib/barrel.dart', "export 'helper.dart' show buildQuery;");
        expectChecked(
          await check(
            "import 'lib/barrel.dart' as queries;\nvoid example(dynamic session, dynamic filters) { session.db.unsafeQuery(queries.buildQuery(filters)); }",
          ),
        );
      },
    );

    test('a bad branch reports the helper return location and validates both branches', () async {
      write(
        'lib/helper.dart',
        "String buildQuery(dynamic filters) {\n  if (filters.a) return 'select 1';\n  return 'select from;';\n}",
      );
      final result = await check(
        "import 'lib/helper.dart';\nvoid example(dynamic session, dynamic filters) { session.db.unsafeQuery(buildQuery(filters)); }",
      );
      expectChecked(result, count: 2, failures: 1);
      expect(result.stderr, contains('FAIL lib/helper.dart:3:22 (variant 2)'));
    });

    test('helper placeholders keep binding checks and their source', () async {
      write('lib/helper.dart', r"String buildQuery() => 'select @id';");
      final result = await check(
        "import 'lib/helper.dart';\nvoid example(dynamic session) { session.db.unsafeQuery(buildQuery()); }",
      );
      expect(result.exitCode, 1);
      expect(result.stderr, contains('FAIL lib/helper.dart:1:32'));
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });

    test(
      'helper argument fragments report errors at the caller argument',
      () async {
        write(
          'lib/helper.dart',
          r"String build(String clause) => 'select 1 $clause';",
        );
        final result = await check(
          "import 'lib/helper.dart';\nvoid example(dynamic session) { session.db.unsafeQuery(build('from;')); }",
        );
        expectChecked(result, failures: 1);
        expect(result.stderr, contains('FAIL endpoint.dart:2:67'));
      },
    );

    for (final major in [17, 18]) {
      test(
        'helper-generated PL/pgSQL is checked on PostgreSQL $major',
        () async {
          write(
            'lib/helper.dart',
            r"String buildQuery() => r'DO $$ BEGIN IF THEN END IF; END; $$;';",
          );
          final result = await check(
            "import 'lib/helper.dart'; void example(dynamic session) { session.db.unsafeQuery(buildQuery()); }",
            major: major,
          );
          expectChecked(result, failures: 1);
          expect(result.stderr, contains('FAIL lib/helper.dart:1:'));
          expect(result.stderr, contains('PL/pgSQL:'));
        },
      );
    }

    final unsupported = <String, String>{
      'runtime return': 'String buildQuery(dynamic f) => f.sql;',
      'unknown branch': "String buildQuery(dynamic f) { if (f.a) return 'select 1'; return f.sql; }",
      'fallthrough':
          "String? buildQuery(dynamic f) { if (f.a) return 'select 1'; }",
      'recursion': 'String buildQuery(dynamic f) => buildQuery(f);',
      'mutual recursion': 'String buildQuery(dynamic f) => other(f); String other(dynamic f) => buildQuery(f);',
      'mutation': "String buildQuery(dynamic f) { var sql = 'select 1'; sql += f.sql; return sql; }",
      'loop': "String buildQuery(dynamic f) { for (final value in f.values) { return 'select 1'; } return 'select 2'; }",
      'async': "Future<String> buildQuery(dynamic f) async => 'select 1';",
      'side-effect statement':
          "String buildQuery(dynamic f) { print(f); return 'select 1'; }",
    };
    test('parameter assignment in condition checks the assigned SQL', () async {
      final result = await check(
        r"String buildQuery(dynamic f) { if ((f = 'invalid') == 'invalid') return '$f'; return 'select 1'; } void example(dynamic session, dynamic f) { session.db.unsafeQuery(buildQuery(f)); }",
      );
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('syntax error at or near "invalid"'));
    });
    for (final entry in unsupported.entries) {
      test('${entry.key} remains skipped', () async {
        expectSkipped(
          await check(
            '${entry.value}\nvoid example(dynamic session, dynamic filters) { session.db.unsafeQuery(buildQuery(filters)); }',
          ),
        );
      });
    }

    test('runtime table argument stays unknown', () async {
      expectSkipped(
        await check(
          r"String build(String table) => 'select * from $table'; void example(dynamic session, String table) { session.db.unsafeQuery(build(table)); }",
        ),
      );
    });

    test('helper name shadowed by a runtime parameter stays unknown', () async {
      expectSkipped(
        await check(
          "String buildQuery() => 'select 1'; void example(dynamic session, dynamic buildQuery) { session.db.unsafeQuery(buildQuery()); }",
        ),
      );
    });

    test(
      'instance helpers stay unknown because receivers can override them',
      () async {
        expectSkipped(
          await check(
            "class Queries { String buildQuery() => 'select 1'; } void example(dynamic session, Queries q) { session.db.unsafeQuery(q.buildQuery()); }",
          ),
        );
      },
    );

    test('missing and extra helper arguments stay unknown', () async {
      expectSkipped(
        await check(
          "String buildQuery(String unused) => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(buildQuery()); }",
        ),
      );
      expectSkipped(
        await check(
          "String buildQuery() => 'select 1'; void example(dynamic session) { session.db.unsafeQuery(buildQuery('unused')); }",
        ),
      );
    });

    test('more than 32 return variants stay unknown', () async {
      final branches = [
        for (var i = 0; i < 32; i++) "if (f.x$i) return 'select $i';",
      ].join('\n');
      expectSkipped(
        await check(
          "String buildQuery(dynamic f) { $branches return 'select 32'; } void example(dynamic session, dynamic filters) { session.db.unsafeQuery(buildQuery(filters)); }",
        ),
      );
    });
  });
}
