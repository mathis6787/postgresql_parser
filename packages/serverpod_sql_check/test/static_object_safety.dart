import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void staticObjectSafetyTests(
  Directory Function() fixture,
  Future<ProcessResult> Function(Directory, List<String>) run,
) {
  Future<ProcessResult> check(String source) {
    expect(
      parseString(content: source, throwIfDiagnostics: false).errors,
      isEmpty,
    );
    final file = File(p.join(fixture().path, 'endpoint.dart'));
    file.writeAsStringSync(source);
    return run(fixture(), ['--root=${fixture().path}', '--verbose', file.path]);
  }

  void skipped(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 0 SQL variants; 0 failed; 1 dynamic'),
    );
  }

  group('static object safety', () {
    test(
      'partial SQL keyword prefixes remain eligible for template checks',
      () async {
        final result = await check(
          r"const suffix = 'ECT 1'; final sql = 'SEL$suffix';",
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Checked 1 SQL variants; 0 failed; 0 dynamic'),
        );
      },
    );
    test('query inside try observes earlier map mutations', () async {
      final result = await check('''
void example(dynamic session) {
  try {
    final params = {'id': 1};
    params.clear();
    session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params));
  } finally {}
}
''');
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
    test(
      'query inside an unknown loop does not reuse stale map keys',
      () async {
        final result = await check('''
void example(dynamic session, bool flag) {
  final params = {'id': 1};
  while (flag) {
    params.clear();
    session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params));
  }
}
''');
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('0 missing bindings; 1 binding checks skipped.'),
        );
      },
    );
    final flags = [for (var i = 0; i < 6; i++) 'f$i'];
    final arguments = flags.join(', ');
    final parameters = flags.map((flag) => 'bool $flag').join(', ');
    final wide = flags.map((flag) => "($flag ? 'x' : 'y')").join(' + ');
    for (final setup in <String, String>{
      'list': 'final sql = [wide($arguments)].join();',
      'buffer':
          'final buffer = StringBuffer()..write(wide($arguments)); final sql = buffer.toString();',
      'object':
          'final object = Builder(wide($arguments)); final sql = object.sql;',
      'record':
          'final record = (sql: wide($arguments),); final sql = record.sql;',
    }.entries) {
      test(
        'expansion overflow inside a ${setup.key} remains skipped',
        () async {
          skipped(
            await check('''
class Builder { final String sql; Builder(this.sql); }
String wide($parameters) => $wide;
void example(dynamic session, $parameters) {
  ${setup.value}
  session.db.unsafeQuery(sql);
}
'''),
          );
        },
      );
    }
    for (final operator in ['value == value', '-value']) {
      test(
        'opaque operator $operator invalidates readable object contents',
        () async {
          skipped(
            await check('''
class Builder {
  final Map<String, String> parameters;
  Builder(this.parameters);
  bool operator ==(Object other) { parameters.clear(); return true; }
  Builder operator -() { parameters.clear(); return this; }
}
void example(dynamic session) {
  final value = Builder({'sql': 'select 1'});
  $operator;
  session.db.unsafeQuery(value.parameters['sql']!);
}
'''),
          );
        },
      );
    }
    test(
      'binary list assembly uses mutations from its right operand',
      () async {
        final result = await check('''
List<String> suffix(List<String> parts, bool flag) {
  if (flag) parts.clear();
  return ['1'];
}
void example(dynamic session, bool flag) {
  final parts = ['select '];
  final sql = parts + suffix(parts, flag);
  session.db.unsafeQuery(sql.join());
}
''');
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Checked 2 SQL variants; 1 failed; 0 dynamic'),
        );
      },
    );
    test('another constructor cannot resolve an unknown this field', () async {
      skipped(
        await check('''
class Builder {
  final String sql;
  Builder(this.sql);
  void example(dynamic session) {
    final other = Builder('select 1');
    session.db.unsafeQuery(sql);
  }
}
'''),
      );
    });

    test('another constructor retains the current receiver fields', () async {
      final result = await check('''
class Builder {
  final String sql;
  Builder(this.sql);
  String build() {
    final other = Builder('select 1');
    return sql;
  }
}
void example(dynamic session) {
  session.db.unsafeQuery(Builder('select from;').build());
}
''');
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stdout,
        contains('Checked 1 SQL variants; 1 failed; 0 dynamic'),
      );
    });

    test('nested helpers restore the receiver from each branch', () async {
      skipped(
        await check('''
class Builder {
  final Map<String, String> parameters;
  Builder(this.parameters);
  String inner(bool flag) {
    if (flag) parameters.clear();
    return 'ignored';
  }
  String middle(bool flag) => inner(flag);
  String build(bool flag) {
    final ignored = middle(flag);
    return (this).parameters['sql']!;
  }
}
void example(dynamic session, bool flag) {
  session.db.unsafeQuery(Builder({'sql': 'select 1'}).build(flag));
}
'''),
      );
    });

    test('static helpers remain distinct from named constructors', () async {
      final result = await check('''
class Queries {
  static String build() => 'select 1';
}
void example(dynamic session) {
  session.db.unsafeQuery(Queries.build());
}
''');
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stdout,
        contains('Checked 1 SQL variants; 0 failed; 0 dynamic'),
      );
    });

    for (final entry in <String, String>{
      'objects nested in list records': "final queries = [(statement: Statement('select @id', {'id': 1}),)]; final statement = queries[0].statement;",
      'records nested in maps': "final queries = {'active': (text: 'select @id', parameters: {'id': 1})}; final statement = queries['active']!;",
    }.entries) {
      test('${entry.key} retain independent temporary anchors', () async {
        final result = await check('''
class Statement {
  final String text;
  final Map<String, Object?> parameters;
  Statement(this.text, this.parameters);
}
void example(dynamic session) {
  ${entry.value}
  session.db.unsafeQuery(statement.text,
    parameters: QueryParameters.named(statement.parameters));
}
''');
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Checked 1 SQL variants; 0 failed; 0 dynamic'),
        );
        expect(
          result.stdout,
          contains(
            'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
          ),
        );
      });
    }

    test(
      'list record branches retain matching SQL and parameter maps',
      () async {
        final result = await check('''
void example(dynamic session, bool flag) {
  final queries = [(text: flag ? 'select @id' : 'select 1',
    parameters: {if (flag) 'id': 1})];
  final statement = queries[0];
  session.db.unsafeQuery(statement.text,
    parameters: QueryParameters.named(statement.parameters));
}
''');
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('Checked 2 SQL variants; 0 failed; 0 dynamic'),
        );
        expect(
          result.stdout,
          contains(
            'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
          ),
        );
      },
    );

    test('constructor backups retain caller parameter map aliases', () async {
      final result = await check('''
class Builder {
  final Map<String, Object?> parameters;
  Builder(this.parameters);
  String build() {
    final other = Builder({'id': 1});
    parameters.clear();
    return 'select @id';
  }
}
void example(dynamic session) {
  final parameters = {'id': 1};
  session.db.unsafeQuery(Builder(parameters).build(),
    parameters: QueryParameters.named(parameters));
}
''');
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
  });
}
