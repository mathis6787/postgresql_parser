import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void staticGetterTests(
  Directory Function() fixture,
  Future<ProcessResult> Function(Directory, List<String>) run,
) {
  Future<ProcessResult> check(
    String source, {
    Map<String, String> files = const {},
  }) {
    expect(
      parseString(content: source, throwIfDiagnostics: false).errors,
      isEmpty,
    );
    for (final entry in files.entries) {
      File(p.join(fixture().path, entry.key)).writeAsStringSync(entry.value);
    }
    final file = File(p.join(fixture().path, 'endpoint.dart'));
    file.writeAsStringSync(source);
    return run(fixture(), ['--root=${fixture().path}', '--verbose', file.path]);
  }

  void checked(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('0 dynamic queries/templates skipped.'));
  }

  void skipped(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('1 dynamic queries/templates skipped.'));
  }

  group('readable getters and registries', () {
    test(
      'top-level and static getters retain namespace and bindings',
      () async {
        checked(
          await check('''
String get sql => Query.sql;
class Query { static String get sql => 'select @id'; }
void example(dynamic session) {
  session.db.unsafeQuery(sql, parameters: QueryParameters.named({'id': 1}));
}
'''),
        );
      },
    );
    test(
      'getter/setter pairs read their getter in either declaration order',
      () async {
        checked(
          await check('''
set sql(String ignored) {}
String get sql => Query.sql;
class Query {
  static String get sql => 'select 1';
  static set sql(String ignored) {}
}
void example(dynamic session) { session.db.unsafeQuery(sql); }
'''),
        );
      },
    );
    test('getters resolve through prefixes and reexports', () async {
      checked(
        await check(
          '''
import 'barrel.dart' as queries;
void example(dynamic session) { session.db.unsafeQuery(queries.Registry.sql); }
''',
          files: {
            'barrel.dart': "export 'queries.dart' show Registry;",
            'queries.dart':
                "class Registry { static String get sql => 'select 1'; }",
          },
        ),
      );
    });
    test(
      'constant object registry evaluates each getter in definition order',
      () async {
        checked(
          await check(r'''
class Locale {
  final String tag;
  const Locale(this.tag);
  String get suffix => tag.toLowerCase().replaceAll('-', '_');
  String get indexName => 'items_search_$suffix';
}
class Registry {
  static const values = [Locale('en-CA'), Locale('fr-CA')];
}
void example(dynamic session) {
  for (final locale in Registry.values) {
    session.db.unsafeQuery('create index ${locale.indexName} on items (id)');
  }
}
'''),
        );
      },
    );
    test(
      'imported class constants survive unrelated old final formals',
      () async {
        checked(
          await check(
            r'''
import 'keys.dart';
import 'dependency.dart';
void example(dynamic session) {
  session.db.unsafeQuery('select ${Keys.number}');
}
''',
            files: {
              'keys.dart': "class Keys { static const number = '1'; }",
              'dependency.dart': 'void unrelated(final String value) {}',
            },
          ),
        );
      },
    );
    test(
      'namespace traversal keeps all export diamond and cycle conflicts',
      () async {
        skipped(
          await check(
            r'''
import 'barrel.dart';
void example(dynamic session) { session.db.unsafeQuery(Keys.sql); }
''',
            files: {
              'barrel.dart': "export 'left.dart'; export 'right.dart';",
              'left.dart': "export 'shared.dart'; export 'a.dart';",
              'right.dart': "export 'shared.dart'; export 'b.dart';",
              'shared.dart': "export 'barrel.dart';",
              'a.dart': "class Keys { static const sql = 'select 1'; }",
              'b.dart': "class Keys { static const sql = 'select from;'; }",
            },
          ),
        );
      },
    );
    test(
      'old final modifiers never hide same-name namespace conflicts',
      () async {
        skipped(
          await check(
            '''
import 'keys.dart';
import 'dependency.dart';
void example(dynamic session) { session.db.unsafeQuery(Keys.sql); }
''',
            files: {
              'keys.dart': "class Keys { static const sql = 'select 1'; }",
              'dependency.dart': "void unrelated(final String value) {} class Keys { static const sql = 'select from;'; }",
            },
          ),
        );
      },
    );
    test(
      'arbitrary malformed dependency remains an uncertain namespace',
      () async {
        skipped(
          await check(
            '''
import 'keys.dart';
import 'dependency.dart';
void example(dynamic session) { session.db.unsafeQuery(Keys.sql); }
''',
            files: {
              'keys.dart': "class Keys { static const sql = 'select 1'; }",
              'dependency.dart': 'class Broken { void method( {',
            },
          ),
        );
      },
    );
    test(
      'getter in a source with final modifier diagnostics stays unreadable',
      () async {
        skipped(
          await check(
            '''
import 'dependency.dart';
void example(dynamic session) { session.db.unsafeQuery(sql); }
''',
            files: {
              'dependency.dart': "void unrelated(final String value) {} String get sql => 'select 1';",
            },
          ),
        );
      },
    );
    test('enum constants and switch cases work across imports', () async {
      checked(
        await check(
          '''
import 'choices.dart' as choices;
String sql(choices.Choice value) => switch (value) {
  choices.Choice.first => 'select 1',
  choices.Choice.second => 'select 2',
};
void example(dynamic session) {
  for (final value in choices.Choice.values) {
    session.db.unsafeQuery(sql(value));
  }
}
''',
          files: {'choices.dart': 'enum Choice { first, second }'},
        ),
      );
    });
    for (final getter in {
      'runtime': 'String get sql => runtimeSql();',
      'recursive': 'String get sql => sql;',
      'mutable global': "String value = 'select 1'; String get sql => value;",
    }.entries) {
      test('${getter.key} getter remains skipped', () async {
        skipped(
          await check('''
${getter.value}
void example(dynamic session) { session.db.unsafeQuery(sql); }
'''),
        );
      });
    }
  });

  group('safe partial receivers and factories', () {
    test(
      'another instance helper cannot replace known caller field values',
      () async {
        final result = await check('''
class Builder {
  final String sql;
  Builder(this.sql);
  String getSql() => sql;
  String outer() {
    final other = Builder('select 1');
    other.getSql();
    return sql;
  }
}
void example(dynamic session) {
  session.db.unsafeQuery(Builder('select from;').outer());
}
''');
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stderr, contains('syntax error'));
        expect(result.stdout, contains('0 dynamic queries/templates skipped.'));
      },
    );
    test(
      'another instance helper cannot resolve a partial receiver field',
      () async {
        skipped(
          await check('''
class Builder {
  final String _sql;
  Builder(this._sql);
  String getSql() => _sql;
  String _build() {
    Builder('select 1').getSql();
    return _sql;
  }
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}
'''),
        );
      },
    );
    test(
      'private helper reads immutable declaration-initialized fields',
      () async {
        checked(
          await check(r'''
class Builder {
  final String _table = 'items';
  String get _sql => 'select * from $_table';
  String _build() => _sql;
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}
'''),
        );
      },
    );
    test('final class public helper can read a scalar initializer', () async {
      checked(
        await check('''
final class Builder {
  final String sql = 'select 1';
  String build() => sql;
  void example(dynamic session) { session.db.unsafeQuery(build()); }
}
'''),
      );
    });
    test(
      'private builder can be declared on a class with an unknown superclass',
      () async {
        checked(
          await check('''
class Builder extends Endpoint {
  final String _sql = 'select 1';
  String _build() => _sql;
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}
'''),
        );
      },
    );
    test(
      'known superclass does not hide an unshadowed core constructor',
      () async {
        checked(
          await check('''
class Base {}
class Builder extends Base {
  String _build() {
    final buffer = StringBuffer()..write('select 1');
    return buffer.toString();
  }
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}
'''),
        );
      },
    );
    test('inherited constructor-shaped getter shadows the core name', () async {
      skipped(
        await check('''
class Base { dynamic get StringBuffer => runtimeFactory(); }
class Builder extends Base {
  String _build() {
    final buffer = StringBuffer()..write('select 1');
    return buffer.toString();
  }
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}
'''),
      );
    });
    for (final builder in {
      'unknown constructor field': '''
class Builder {
  final String _sql;
  Builder(this._sql);
  String _build() => _sql;
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}''',
      'public overridable helper': '''
class Builder {
  String build() => 'select 1';
  void example(dynamic session) { session.db.unsafeQuery(build()); }
}''',
      'local private override': '''
class Builder {
  String _build() => 'select 1';
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}
class Other extends Builder { String _build() => runtimeSql(); }''',
      'mutable final collection initializer': '''
class Builder {
  final Map<String, String> _queries = {'sql': 'select 1'};
  String _build() => _queries['sql']!;
  void example(dynamic session) { session.db.unsafeQuery(_build()); }
}''',
    }.entries) {
      test('${builder.key} remains skipped', () async {
        skipped(await check(builder.value));
      });
    }
    test(
      'readable expression factory returns a concrete generative object',
      () async {
        checked(
          await check('''
class Query {
  final String sql;
  Query._(this.sql);
  factory Query(String sql) => Query._(sql);
}
void example(dynamic session) { session.db.unsafeQuery(Query('select 1').sql); }
'''),
        );
      },
    );
    test(
      'redirect factory can reach its private constructor through an import',
      () async {
        checked(
          await check(
            '''
import 'query.dart';
void example(dynamic session) { session.db.unsafeQuery(Query('select 1').sql); }
''',
            files: {
              'query.dart': '''
class Query {
  final String sql;
  Query._(this.sql);
  factory Query(String sql) = Query._;
}
''',
            },
          ),
        );
      },
    );
    test(
      'factory redirect with different optional defaults stays skipped',
      () async {
        skipped(
          await check('''
class Query {
  final String sql;
  Query._([this.sql = 'select from;']);
  factory Query([String sql = 'select 1']) = Query._;
}
void example(dynamic session) { session.db.unsafeQuery(Query().sql); }
'''),
        );
      },
    );
    test('recursive factory remains skipped', () async {
      skipped(
        await check('''
class Query {
  final String sql;
  Query._(this.sql);
  factory Query(String sql) => Query(sql);
}
void example(dynamic session) { session.db.unsafeQuery(Query('select 1').sql); }
'''),
      );
    });
  });
}
