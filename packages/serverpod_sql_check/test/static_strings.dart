import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Core string operations and finite collection views without app execution.
void staticStringTests(
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

  void checked(ProcessResult result, {int count = 1}) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked $count SQL variants; 0 failed; 0 dynamic'),
    );
  }

  void skipped(ProcessResult result) {
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('Checked 0 SQL variants; 0 failed; 1 dynamic'),
    );
  }

  group('readable core strings', () {
    final operations = <String, String>{
      'lowercase': "'select 1'.toLowerCase()",
      'uppercase': "'select 1'.toUpperCase()",
      'trim': "'  select 1  '.trim()",
      'trimLeft': "'  select 1'.trimLeft()",
      'trimRight': "'select 1  '.trimRight()",
      'replaceAll': "'select TOKEN'.replaceAll('TOKEN', '1')",
      'replaceFirst': "'select TOKEN'.replaceFirst('TOKEN', '1')",
      'replaceFirst index': "'select TOKEN'.replaceFirst('TOKEN', '1', 7)",
      'substring': "'xxselect 1'.substring(2)",
      'substring range': "'xxselect 1yy'.substring(2, 10)",
      'split join': "'select,1'.split(',').join(' ')",
      'split map trim':
          "'select, 1 '.split(',').map((part) => part.trim()).join(' ')",
      'contains': "'choose'.contains('cho') ? 'select 1' : runtimeSql",
      'startsWith': "'choose'.startsWith('cho') ? 'select 1' : runtimeSql",
      'endsWith': "'choose'.endsWith('ose') ? 'select 1' : runtimeSql",
      'isEmpty': "''.isEmpty ? 'select 1' : runtimeSql",
      'isNotEmpty': "'x'.isNotEmpty ? 'select 1' : runtimeSql",
      'Unicode trim and case':
          r'''"  select 'équipement'  ".trim().toUpperCase()''',
    };
    for (final entry in operations.entries) {
      test(entry.key, () async {
        checked(
          await check(
            'void example(dynamic session, String runtimeSql) { session.db.unsafeQuery(${entry.value}); }',
          ),
        );
      });
    }
    for (final entry in <String, String>{
      'negative substring': "'select 1'.substring(-1)",
      'reversed substring': "'select 1'.substring(5, 1)",
      'oversized substring': "'select 1'.substring(0, 99)",
      'runtime substring': "'select 1'.substring(offset)",
      'runtime replacement': "'select TOKEN'.replaceAll('TOKEN', runtimeSql)",
      'regex replacement': "'select TOKEN'.replaceAll(RegExp('TOKEN'), '1')",
      'invalid startsWith range':
          "'select 1'.startsWith('select', 99) ? 'select 1' : runtimeSql",
    }.entries) {
      test('${entry.key} remains unknown', () async {
        skipped(
          await check(
            'void example(dynamic session, String runtimeSql, int offset) { session.db.unsafeQuery(${entry.value}); }',
          ),
        );
      });
    }
    test('substring preserves original error location', () async {
      const source =
          "void example(dynamic session) { const text = 'xxselect );yy'; session.db.unsafeQuery(text.substring(2, 11)); }";
      final result = await check(source);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('endpoint.dart:1:${source.indexOf(');yy') + 1}:'),
      );
    });
    test('replacement preserves replacement literal error location', () async {
      const source =
          "void example(dynamic session) { session.db.unsafeQuery('select TOKEN;'.replaceAll('TOKEN', ')')); }";
      final result = await check(source);
      expect(result.exitCode, 1);
      final offset = source.indexOf("')'") + 1;
      expect(result.stderr, contains('endpoint.dart:1:${offset + 1}:'));
    });
  });

  group('finite core collection operations', () {
    final operations = <String, String>{
      'map keys': "final values = {'select': 0, '1': 0}.keys;",
      'map values': "final values = {'s': 'select', 'n': '1'}.values;",
      'map entries projection': "final values = {'select': 0, '1': 0}.entries.map((entry) => entry.key);",
      'list mapping':
          "final values = ['select', '1'].map((value) => value.trim());",
      'list filter': "final values = ['select 1', 'unused'].where((value) => value.startsWith('select'));",
      'list copy from': "final original = ['select', '1']; final values = List<String>.from(original); original.clear();",
      'list copy of': "final original = ['select', '1']; final values = List<String>.of(original); original.clear();",
      'live map values': "final original = {'s': 'unused'}; final values = original.values; original['s'] = 'select 1';",
      'live list map': "final original = ['select']; final values = original.map((part) => part); original.add('1');",
      'snapshot toList': "final original = {'s': 'select 1'}; final values = original.values.toList(growable: false); original.clear();",
      'constant callback capture': "const suffix = '1'; final values = ['select '].map((part) => part + suffix);",
      'map callback projection': "final original = {'s': ' select ', 'n': '1 '}; final copy = original.map((key, value) => MapEntry(key.toUpperCase(), value.trim())); final values = copy.values;",
      'map callback block': "final original = {'s': 'select', 'n': '1'}; final values = original.entries.map((entry) { final part = entry.value; return part.trim(); });",
    };
    for (final entry in operations.entries) {
      test(entry.key, () async {
        checked(
          await check(
            'void example(dynamic session) { ${entry.value} session.db.unsafeQuery(values.join(" ")); }',
          ),
        );
      });
    }
    test('map copies retain keys after original mutation', () async {
      final result = await check(
        "void example(dynamic session) { final original = {'id': 1}; final copy = Map<String, Object?>.from(original); original.clear(); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(copy)); }",
      );
      checked(result);
      expect(
        result.stdout,
        contains(
          'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
        ),
      );
    });
    test('map of and unmodifiable copies retain keys', () async {
      for (final constructor in ['of', 'unmodifiable']) {
        final result = await check(
          "void example(dynamic session) { final original = {'id': 1}; final copy = Map<String, Object?>.$constructor(original); original.clear(); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(copy)); }",
        );
        checked(result);
        expect(
          result.stdout,
          contains(
            'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
          ),
        );
      }
    });
    test('map copies preserve shallow nested aliases', () async {
      final result = await check(
        "void example(dynamic session) { final nested = {'id': 1}; final original = {'params': nested}; final copy = Map<String, Object?>.from(original); nested.clear(); session.db.unsafeQuery('select @id', parameters: QueryParameters.named(copy['params'])); }",
      );
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('missing named parameter binding for @id'),
      );
    });
    for (final entry in <String, String>{
      'escaped map view': "final map = {'s': 'select 1'}; final values = map.values; escape(map);",
      'escaped list view': "final items = ['select 1']; final values = items.map((part) => part); escape(items);",
      'mutable callback capture': "var prefix = 'select '; final values = ['1'].map((part) => prefix + part); prefix = runtimeSql;",
      'runtime iterable':
          "final values = runtimeItems.map((part) => part.trim());",
    }.entries) {
      test('${entry.key} remains unknown', () async {
        skipped(
          await check(
            'void example(dynamic session, String runtimeSql, List<String> runtimeItems) { ${entry.value} session.db.unsafeQuery(values.join(" ")); }',
          ),
        );
      });
    }
    test('returned callback never reads overwritten callee locals', () async {
      skipped(
        await check(
          "Iterable<String> make(String prefix) => ['1'].map((part) => prefix + part); void example(dynamic session) { final values = make('select '); make('invalid'); session.db.unsafeQuery(values.join()); }",
        ),
      );
    });
    test('shadowed Map constructor is not treated as a core copy', () async {
      skipped(
        await check(
          "class Map { Map.from(dynamic source); String get text => runtimeSql(); } void example(dynamic session) { session.db.unsafeQuery(Map.from({'sql': 'select 1'}).text); }",
        ),
      );
    });
    test('shadowed List constructor is not treated as a core copy', () async {
      skipped(
        await check(
          "class List { List.from(dynamic source); String join() => runtimeSql(); } void example(dynamic session) { session.db.unsafeQuery(List.from(['select 1']).join()); }",
        ),
      );
    });
    test('split expansion limit stays unknown', () async {
      final text = List.filled(33, 'x').join(',');
      skipped(
        await check(
          "void example(dynamic session) { session.db.unsafeQuery('$text'.split(',').join()); }",
        ),
      );
    });
    test('map callback requires readable string keys', () async {
      skipped(
        await check(
          "void example(dynamic session, String runtimeKey) { final original = {'s': 'select 1'}; final copy = original.map((key, value) => MapEntry(runtimeKey, value)); session.db.unsafeQuery(copy.values.join()); }",
        ),
      );
    });
    test('shadowed MapEntry constructor remains unknown', () async {
      skipped(
        await check(
          "class MapEntry { MapEntry(dynamic key, dynamic value); } void example(dynamic session) { final original = {'s': 'select 1'}; final copy = original.map((key, value) => MapEntry(key, value)); session.db.unsafeQuery(copy.values.join()); }",
        ),
      );
    });
    test('mapped size never invokes the callback', () async {
      for (final property in ['length', 'isEmpty', 'isNotEmpty']) {
        final result = await check(
          "void example(dynamic session) { final params = {'id': 1}; final values = [params].map((value) { value.clear(); return 'ignored'; }); final selected = values.$property; session.db.unsafeQuery(selected == ${property == 'length'
              ? '1'
              : property == 'isEmpty'
              ? 'false'
              : 'true'} ? 'select @id' : runtimeSql(), parameters: QueryParameters.named(params)); }",
        );
        checked(result);
        expect(
          result.stdout,
          contains(
            'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
          ),
        );
      }
    });
    test('mapped first and last invoke only the selected callback', () async {
      for (final property in ['first', 'last']) {
        final inputs = property == 'first'
            ? '<String, int>{}, params'
            : 'params, <String, int>{}';
        final result = await check(
          "void example(dynamic session) { final params = {'id': 1}; final values = [$inputs].map((value) { value.clear(); return 'select @id'; }); final sql = values.$property; session.db.unsafeQuery(sql, parameters: QueryParameters.named(params)); }",
        );
        checked(result);
        expect(
          result.stdout,
          contains(
            'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
          ),
        );
      }
    });
    test('filtered first remains readable for a pure predicate', () async {
      checked(
        await check(
          "void example(dynamic session) { session.db.unsafeQuery(['unused', 'select 1'].where((part) => part.startsWith('select')).first); }",
        ),
      );
    });
    test(
      'partial filtering never applies unconsumed callback effects',
      () async {
        final result = await check(
          "void example(dynamic session) { final params = {'id': 1}; final values = [<String, int>{}, params].where((value) { value.clear(); return true; }); final ignored = values.isEmpty; session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params)); }",
        );
        checked(result);
        expect(
          result.stdout,
          contains(
            'Checked 0 named parameter sets; 0 missing bindings; 1 binding checks skipped.',
          ),
        );
      },
    );
    test(
      'equal primitive helper returns do not multiply query paths',
      () async {
        checked(
          await check('''
int offset(dynamic value) {
  if (value == null) return 0;
  if (value < 0) return 0;
  return 0;
}
void example(dynamic session, dynamic a, dynamic b, dynamic c, dynamic d,
    dynamic e, dynamic f) {
  final one = offset(a);
  final two = offset(b);
  final three = offset(c);
  final four = offset(d);
  final five = offset(e);
  final six = offset(f);
  session.db.unsafeQuery('select 1');
}
'''),
        );
      },
    );
    test('equal helper returns keep differing mutations separate', () async {
      final result = await check('''
int clear(Map<String, int> params, bool flag) {
  if (flag) params.clear();
  return 0;
}
void example(dynamic session, bool flag) {
  final params = {'id': 1};
  final ignored = clear(params, flag);
  session.db.unsafeQuery((flag ? 'select 1' : 'select @id') + ' offset ' + ignored.toString(),
      parameters: QueryParameters.named(params));
}
''');
      checked(result, count: 2);
      expect(
        result.stdout,
        contains(
          'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
        ),
      );
    });
  });

  group('finite enum formal domains', () {
    test('repeated helper switches share the caller enum value', () async {
      final result = await check(r'''
enum Mode { equipment, locations }
String column(Mode mode) => switch (mode) {
  Mode.equipment => 'equipment_id', Mode.locations => 'location_id',
};
String table(Mode mode) => switch (mode) {
  Mode.equipment => 'equipment', Mode.locations => 'locations',
};
void example(dynamic session, Mode mode) {
  final sql = 'select ${column(mode)} from ${table(mode)} '
      'where ${column(mode)} = @${column(mode)}';
  session.db.unsafeQuery(sql, parameters: QueryParameters.named({column(mode): 1}));
}
''');
      checked(result, count: 2);
      expect(
        result.stdout,
        contains(
          'Checked 2 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
        ),
      );
    });
    test('nullable enum null branches preserve binding correlation', () async {
      final result = await check(r'''
enum Mode { equipment, locations }
String query(Mode? mode) => mode == null ? 'select 1' : 'select @${mode.name}';
void example(dynamic session, Mode? mode) {
  session.db.unsafeQuery(query(mode), parameters: QueryParameters.named({
    if (mode != null) mode.name: 1,
  }));
}
''');
      checked(result, count: 3);
      expect(
        result.stdout,
        contains(
          'Checked 2 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
        ),
      );
    });
    test('oversized enum domain remains bounded', () async {
      final names = List.generate(33, (i) => 'v$i').join(',');
      skipped(
        await check(
          "enum Mode { $names } void example(dynamic session, Mode mode) { session.db.unsafeQuery('select ' + mode.index.toString()); }",
        ),
      );
    });
    test('a function typed enum return is not an enum parameter', () async {
      skipped(
        await check(
          "enum Mode { one, two } void example(dynamic session, Mode mode()) { session.db.unsafeQuery('select ' + mode.index.toString()); }",
        ),
      );
    });
    test('concrete objects compared with null retain map contents', () async {
      final result = await check('''
class Box {
  final Map<String, Object?> params;
  Box(this.params);
  bool operator ==(Object other) { params.clear(); return true; }
}
void example(dynamic session) {
  final box = Box({'id': 1});
  final absent = box == null;
  session.db.unsafeQuery(absent ? runtimeSql() : 'select @id', parameters: QueryParameters.named(box.params));
}
''');
      checked(result);
      expect(
        result.stdout,
        contains(
          'Checked 1 named parameter sets; 0 missing bindings; 0 binding checks skipped.',
        ),
      );
    });
  });

  group('finite runtime filtering', () {
    test(
      'runtime enum membership preserves finite subsets and bindings',
      () async {
        final result = await check(r'''
enum Mode { one, two, three }
void example(dynamic session, List<Mode> filter) {
  final selected = Mode.values.where(filter.toSet().contains).toList();
  session.db.unsafeQuery('select 1' + selected.map((value) => ', @' + value.name).join(),
      parameters: QueryParameters.named({for (final value in selected) value.name: 1}));
}
''');
        checked(result, count: 8);
        expect(result.stdout, contains('0 binding checks skipped.'));
      },
    );
    test(
      'returned runtime filters never read overwritten callee captures',
      () async {
        checked(
          await check(r'''
enum Mode { one, two }
Iterable<Mode> select(List<Mode> filter) => Mode.values.where((value) => filter.contains(value));
void example(dynamic session, List<Mode> first, List<Mode> second) {
  final selected = select(first);
  select(second);
  session.db.unsafeQuery('select 1' + selected.map((value) => ' /*' + value.name + '*/').join());
}
'''),
          count: 4,
        );
      },
    );
    test('non boolean filters remain unknown', () async {
      skipped(
        await check(
          "void example(dynamic session) { session.db.unsafeQuery(['select 1'].where((value) => 'yes').join()); }",
        ),
      );
    });
    test('escaped filter sources remain unknown', () async {
      skipped(
        await check(
          "void example(dynamic session, bool Function(String) accept) { final parts = ['select 1']; final selected = parts.where(accept); consume(parts); session.db.unsafeQuery(selected.join()); }",
        ),
      );
    });
    test('firstWhere evaluates a readable predicate', () async {
      checked(
        await check(
          "void example(dynamic session) { session.db.unsafeQuery(['unused', 'select 1'].firstWhere((value) => value.startsWith('select'))); }",
        ),
      );
    });
    test(
      'firstWhere enumerates successful immutable metadata results',
      () async {
        checked(
          await check('''
class Metadata {
  final String tag;
  final String value;
  const Metadata(this.tag, this.value);
}
const metadata = [Metadata('one', '1'), Metadata('two', '2')];
Metadata find(String tag) => metadata.firstWhere((value) => value.tag == tag,
    orElse: () => throw ArgumentError('tag'));
void example(dynamic session, String tag) {
  session.db.unsafeQuery('select ' + find(tag).value);
}
'''),
          count: 2,
        );
      },
    );
    test('singleWhere enumerates successful runtime matches', () async {
      checked(
        await check(
          "void example(dynamic session, bool Function(String) accept) { session.db.unsafeQuery(['select 1', 'select 2'].singleWhere(accept, orElse: () => throw StateError('missing'))); }",
        ),
        count: 2,
      );
    });
    test('unreadable not found fallbacks remain unknown', () async {
      skipped(
        await check(
          "void example(dynamic session, bool Function(String) accept) { session.db.unsafeQuery(['select 1'].firstWhere(accept, orElse: () => runtimeSql())); }",
        ),
      );
    });
  });

  group('database parameter reuse', () {
    test('recognised database calls retain wrapper binding keys', () async {
      final result = await check('''
void example(dynamic session) async {
  final parameters = QueryParameters.named({'id': 1});
  final ignored = await session.db.unsafeQuery('select @id', parameters: parameters);
  session.db.unsafeExecute('select @id + 1', parameters: parameters);
}
''');
      checked(result, count: 2);
      expect(result.stdout, contains('0 binding checks skipped.'));
    });
    test('ordinary database statements retain wrapper binding keys', () async {
      final result = await check('''
void example(dynamic session) {
  final parameters = QueryParameters.named({'id': 1});
  session.db.unsafeExecute('select @id', parameters: parameters);
  session.db.unsafeQuery('select @id + 1', parameters: parameters);
}
''');
      checked(result, count: 2);
      expect(result.stdout, contains('0 binding checks skipped.'));
    });
    test(
      'database parameters still expose nested mutable SQL aliases',
      () async {
        final result = await check('''
void example(dynamic session) {
  final parts = ['select 1'];
  final parameters = QueryParameters.named({'id': parts});
  session.db.unsafeExecute('select @id', parameters: parameters);
  session.db.unsafeQuery(parts.join());
}
''');
        expect(result.exitCode, 0);
        expect(
          result.stdout,
          contains('Checked 1 SQL variants; 0 failed; 1 dynamic'),
        );
      },
    );
    test('parameter argument effects remain visible', () async {
      final result = await check('''
dynamic clear(Map<String, int> params) { params.clear(); return QueryParameters.named(params); }
void example(dynamic session) async {
  final params = {'id': 1};
  final ignored = await session.db.unsafeQuery('select 1', parameters: clear(params));
  session.db.unsafeExecute('select @id', parameters: QueryParameters.named(params));
}
''');
      checked(result, count: 2);
      expect(result.stdout, contains('1 binding checks skipped.'));
    });
    test(
      'arbitrary similarly named helpers still invalidate wrappers',
      () async {
        final result = await check('''
void unsafeQuery(dynamic value) {}
void example(dynamic session) {
  final parameters = QueryParameters.named({'id': 1});
  final ignored = unsafeQuery(parameters);
  session.db.unsafeQuery('select @id', parameters: parameters);
}
''');
        expect(result.exitCode, 0);
        expect(result.stdout, contains('1 binding checks skipped.'));
      },
    );
  });

  for (final capture in [
    'consume(alias);',
    'final hidden = alias; consume(hidden);',
  ]) {
    test('escaped callable captures remain unknown: $capture', () async {
      final result = await check('''
void example(dynamic session) {
  final params = {'id': 1};
  Map<String, int> alias() => params;
  $capture
  session.db.unsafeQuery('select @id', parameters: QueryParameters.named(params));
}
''');
      checked(result);
      expect(result.stdout, contains('1 binding checks skipped.'));
    });
  }

  group('null aware core strings', () {
    test('known null short circuits an entire method chain', () async {
      checked(
        await check(
          "void example(dynamic session) { const String? sql = null; session.db.unsafeQuery(sql?.trim().toUpperCase() ?? 'select 1'); }",
        ),
      );
    });
    test('known value traverses a nullable method chain', () async {
      checked(
        await check(
          "void example(dynamic session) { const String? sql = 'select 1'; session.db.unsafeQuery(sql?.trim().toUpperCase() ?? runtimeSql()); }",
        ),
      );
    });
    test('parentheses end the null short circuit', () async {
      skipped(
        await check(
          "void example(dynamic session) { const String? sql = null; session.db.unsafeQuery((sql?.trim()).toUpperCase() ?? 'select 1'); }",
        ),
      );
    });
    test('stored null ends the null short circuit', () async {
      skipped(
        await check(
          "void example(dynamic session) { const String? sql = null; final copy = sql?.trim(); session.db.unsafeQuery(copy.toUpperCase() ?? 'select 1'); }",
        ),
      );
    });
  });
}
