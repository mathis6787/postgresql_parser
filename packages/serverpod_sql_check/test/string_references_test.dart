import 'dart:io';

import 'package:test/test.dart';

final class _Fixture {
  _Fixture(String source, this.status) : source = source.trimLeft();
  final String source;
  final String status;
}

final _fixtures = <String, _Fixture>{
  'top_const': _Fixture(r'''
const query = 'select from;';
void example(dynamic session) { session.db.unsafeQuery(query); }
''', 'FAIL'),
  'local_final': _Fixture(r'''
void example(dynamic session) {
  final query = 'select from;';
  session.db.unsafeQuery(query);
}
''', 'FAIL'),
  'chained_fragments': _Fixture(r'''
const prefix = 'select';
const suffix = ' from;';
void example(dynamic session) {
  final query = prefix + suffix;
  session.db.unsafeQuery(query);
}
''', 'FAIL'),
  'interpolation': _Fixture(r'''
const clause = 'from;';
void example(dynamic session) {
  final query = 'select 1 $clause';
  session.db.unsafeQuery(query);
}
''', 'FAIL'),
  'adjacent_strings': _Fixture(r'''
const query = 'select ' 'from;';
void example(dynamic session) { session.db.unsafeQuery((query)); }
''', 'FAIL'),
  'conditional_references': _Fixture(r'''
const good = 'select 1;';
const bad = 'select from;';
void example(dynamic session, bool flag) {
  final query = flag ? good : bad;
  session.db.unsafeQuery(query);
}
''', 'FAIL'),
  'parameter_rewrite': _Fixture(r'''
const query = 'select @very_long_parameter_name::uuid from;';
void example(dynamic session) { session.db.unsafeQuery(query, parameters: QueryParameters.named({'very_long_parameter_name': 1})); }
''', 'FAIL'),
  'local_shadows_global': _Fixture(r'''
const query = 'select from;';
void example(dynamic session) {
  final query = 'select 1;';
  session.db.unsafeQuery(query);
}
''', 'OK'),
  'sibling_block_does_not_leak': _Fixture(r'''
const query = 'select 1;';
void example(dynamic session) {
  { final query = 'select from;'; }
  session.db.unsafeQuery(query);
}
''', 'OK'),
  'initializer_scope_not_caller_scope': _Fixture(r'''
const fragment = 'select 1;';
const query = fragment;
void example(dynamic session, String fragment) {
  session.db.unsafeQuery(query);
}
''', 'OK'),
  'parameter_shadows_global': _Fixture(r'''
const query = 'select from;';
void example(dynamic session, String query) {
  session.db.unsafeQuery(query);
}
''', 'SKIP'),
  'closure_parameter_shadows_global': _Fixture(r'''
const query = 'select from;';
void example(dynamic session) {
  final callback = (String query) { session.db.unsafeQuery(query); };
}
''', 'SKIP'),
  'mutable_shadows_global': _Fixture(r'''
const query = 'select from;';
void example(dynamic session) {
  var query = 'select 1;';
  session.db.unsafeQuery(query);
}
''', 'SKIP'),
  'loop_variable_shadows_global': _Fixture(r'''
const query = 'select from;';
void example(dynamic session, List<String> queries) {
  for (final query in queries) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'catch_parameter_shadows_global': _Fixture(r'''
const query = 'select from;';
void example(dynamic session) {
  try { throw ''; } catch (query) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'pattern_variable_shadows_global': _Fixture(r'''
const query = 'select from;';
void example(dynamic session, Object value) {
  if (value case final String query) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'late_final': _Fixture(r'''
void example(dynamic session) {
  late final query = 'select from;';
  session.db.unsafeQuery(query);
}
''', 'SKIP'),
  'runtime_initializer': _Fixture(r'''
void example(dynamic session) {
  final query = buildSql();
  session.db.unsafeQuery(query);
}
''', 'SKIP'),
  'top_forward_reference': _Fixture(r'''
final query = fragment;
final fragment = 'select from;';
void example(dynamic session) { session.db.unsafeQuery(query); }
''', 'FAIL'),
  'local_before_declaration': _Fixture(r'''
const query = 'select from;';
void example(dynamic session) {
  session.db.unsafeQuery(query);
  final query = 'select 1;';
}
''', 'SKIP'),
  'reference_cycle': _Fixture(r'''
final query = other;
final other = query;
void example(dynamic session) { session.db.unsafeQuery(query); }
''', 'SKIP'),
  'unqualified_class_field': _Fixture(r'''
class Queries {
  static const query = 'select from;';
  void example(dynamic session) { session.db.unsafeQuery(query); }
}
''', 'FAIL'),
  'qualified_static_field': _Fixture(r'''
class Queries { static const query = 'select from;'; }
void example(dynamic session) { session.db.unsafeQuery(Queries.query); }
''', 'FAIL'),
  'explicit_instance_field': _Fixture(r'''
class Queries {
  final query = 'select from;';
  void example(dynamic session) { session.db.unsafeQuery(this.query); }
}
''', 'FAIL'),
  'class_parameter_shadows_field': _Fixture(r'''
class Queries {
  final query = 'select from;';
  void example(dynamic session, String query) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'parameter_shadows_class_name': _Fixture(r'''
class Queries { static const query = 'select from;'; }
void example(dynamic session, dynamic Queries) { session.db.unsafeQuery(Queries.query); }
''', 'SKIP'),
  'inherited_member_does_not_resolve_global': _Fixture(r'''
const query = 'select from;';
class Base { final query = 'select 1;'; }
class Derived extends Base {
  void example(dynamic session) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'mixin_member_does_not_resolve_global': _Fixture(r'''
const query = 'select from;';
class Base { final query = 'select 1;'; }
mixin Queries on Base {
  void example(dynamic session) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'extension_receiver_does_not_resolve_global': _Fixture(r'''
const query = 'select from;';
class Base { final query = 'select 1;'; }
extension Queries on Base {
  void example(dynamic session) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'getter_shadows_global': _Fixture(r'''
const query = 'select from;';
class Queries {
  String get query => buildSql();
  void example(dynamic session) { session.db.unsafeQuery(query); }
}
''', 'SKIP'),
  'imported_value': _Fixture(r'''
import 'unresolved_constants.dart';
void example(dynamic session) { session.db.unsafeQuery(importedSql); }
''', 'SKIP'),
};

void main() {
  late Directory directory;
  late ProcessResult result;
  final findings = <String, List<String>>{};

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('sql_string_references_');
    for (final entry in _fixtures.entries) {
      await File('${directory.path}/${entry.key}.dart')
          .writeAsString(entry.value.source);
    }
    result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/serverpod_sql_check.dart',
      '--verbose',
      '--root=${directory.path}',
    ], workingDirectory: Directory.current.path);
    final lines = '${result.stdout}\n${result.stderr}'.split('\n');
    for (final line in lines) {
      final match = RegExp(r'\b(OK|FAIL|SKIP) ([^:\s]+)\.dart:')
          .firstMatch(line);
      if (match != null) {
        findings
            .putIfAbsent(match.group(2)!, () => [])
            .add(line.substring(match.start));
      }
    }
  });

  tearDownAll(() async {
    await directory.delete(recursive: true);
  });

  for (final entry in _fixtures.entries) {
    test(entry.key, () {
      final lines = findings[entry.key] ?? [];
      expect(lines, isNotEmpty, reason: '${result.stdout}\n${result.stderr}');
      expect(
        lines.any((line) => line.startsWith(entry.value.status)),
        isTrue,
        reason: lines.join('\n'),
      );
      if (entry.value.status != 'FAIL') {
        expect(
          lines.any((line) => line.startsWith('FAIL')),
          isFalse,
          reason: 'An unrelated shadowed string must not be checked.',
        );
      }
      if (entry.value.status == 'FAIL') {
        final source = entry.value.source;
        final offset = source.indexOf('from;') + 'from;'.length - 1;
        final prefix = source.substring(0, offset);
        final line = '\n'.allMatches(prefix).length + 1;
        final column = prefix.length - prefix.lastIndexOf('\n');
        expect(
          lines.where((line) => line.startsWith('FAIL')),
          everyElement(contains('${entry.key}.dart:$line:$column')),
          reason: 'The error must point to the original initializer.',
        );
      }
    });
  }

  test('syntax failures give a nonzero exit code', () {
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
  });
}
