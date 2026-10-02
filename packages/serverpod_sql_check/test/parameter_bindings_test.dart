import 'dart:io';

import 'package:test/test.dart';

final class _Fixture {
  _Fixture(
    String source, {
    this.missing = const [],
    this.skipped = false,
    this.lastOccurrence = false,
  }) : source = source.trimLeft();

  final String source;
  final List<String> missing;
  final bool skipped;
  final bool lastOccurrence;
}

final _fixtures = <String, _Fixture>{
  'missing_key': _Fixture(
    r'''
void example(dynamic session, dynamic tenant) {
  session.db.unsafeQuery('select @tenant_id::uuid;', parameters: QueryParameters.named({'tenant': tenant}));
}
''',
    missing: ['tenant_id'],
  ),
  'matching_runtime_value': _Fixture(r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id::uuid;', parameters: QueryParameters.named({'tenant_id': loadTenant().toString()}));
}
'''),
  'empty_map': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({}));
}
''',
    missing: ['tenant_id'],
  ),
  'omitted_parameters': _Fixture(
    r'''
void example(dynamic session) { session.db.unsafeQuery('select @tenant_id;'); }
''',
    missing: ['tenant_id'],
  ),
  'null_parameters': _Fixture(
    r'''
void example(dynamic session) { session.db.unsafeQuery('select @tenant_id;', parameters: null); }
''',
    missing: ['tenant_id'],
  ),
  'unsafe_execute': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeExecute('delete from things where id = @id;', parameters: QueryParameters.named({'tenant': 1}));
}
''',
    missing: ['id'],
  ),
  'repeated_parameter': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @id, @id;', parameters: QueryParameters.named({}));
}
''',
    missing: ['id'],
  ),
  'multiple_missing': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id, @id, @bound;', parameters: QueryParameters.named({'bound': 1}));
}
''',
    missing: ['tenant_id', 'id'],
  ),
  'case_sensitive_keys': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({'Tenant_id': 1}));
}
''',
    missing: ['tenant_id'],
  ),
  'extra_keys': _Fixture(r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @id;', parameters: QueryParameters.named({'id': 1, 'unused': 2}));
}
'''),
  'comments_and_quotes': _Fixture(r"""
void example(dynamic session) {
  session.db.unsafeQuery(r'''select 'it''s @string', "@identifier", $tag$@body$tag$, @bound
-- @line_comment
/* @block_comment /* @nested_comment */ */;
''', parameters: QueryParameters.named({'bound': 1}));
}
"""),
  'quoted_text_without_parameters': _Fixture(r"""
void example(dynamic session) {
  session.db.unsafeQuery(r'''select '@string', "@identifier", $$@body$$; -- @comment
''');
}
"""),
  'referenced_sql_origin': _Fixture(
    r'''
const query = 'select @tenant_id::uuid;';
void example(dynamic session) {
  session.db.unsafeQuery(query, parameters: QueryParameters.named({'tenant': 1}));
}
''',
    missing: ['tenant_id'],
  ),
  'interpolated_sql_origin': _Fixture(
    r'''
const clause = '@tenant_id';
void example(dynamic session) {
  final query = 'select $clause;';
  session.db.unsafeQuery(query, parameters: QueryParameters.named({'tenant': 1}));
}
''',
    missing: ['tenant_id'],
  ),
  'escaped_unicode_origin': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery("select '😀',\n @tenant_id;", parameters: QueryParameters.named({}));
}
''',
    missing: ['tenant_id'],
  ),
  'constant_key': _Fixture(r'''
const key = 'tenant_id';
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({key: 1}));
}
'''),
  'composed_key': _Fixture(r'''
void example(dynamic session) {
  const suffix = 'id';
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({'tenant_$suffix': 1}));
}
'''),
  'shadowed_key': _Fixture(r'''
const key = 'tenant_id';
void example(dynamic session, String key) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({key: 1}));
}
''', skipped: true),
  'spread_map': _Fixture(r'''
void example(dynamic session, Map<String, Object?> extras) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({'id': 1, ...extras}));
}
''', skipped: true),
  'conditional_entry': _Fixture(r'''
void example(dynamic session, bool flag) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({if (flag) 'tenant_id': 1}));
}
''', skipped: true),
  'loop_entry': _Fixture(r'''
void example(dynamic session, List<String> keys) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({for (final key in keys) key: 1}));
}
''', skipped: true),
  'map_variable': _Fixture(r'''
void example(dynamic session) {
  final parameters = {'tenant_id': 1};
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named(parameters));
}
'''),
  'positional_parameters': _Fixture(r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.positional([1]));
}
''', skipped: true),
  'query_parameters_variable': _Fixture(r'''
void example(dynamic session) {
  final parameters = QueryParameters.named({'tenant_id': 1});
  session.db.unsafeQuery('select @tenant_id;', parameters: parameters);
}
'''),
  'prefixed_constructor': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: pod.QueryParameters.named({'tenant': 1}));
}
''',
    missing: ['tenant_id'],
  ),
  'explicit_new_constructor': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: new QueryParameters.named({'tenant': 1}));
}
''',
    missing: ['tenant_id'],
  ),
  'parenthesized_typed_map': _Fixture(r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: (QueryParameters.named((<String, Object?>{'tenant_id': 1}))));
}
'''),
  'maps_are_per_call': _Fixture(
    r'''
void example(dynamic session) {
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({'tenant_id': 1}));
  session.db.unsafeQuery('select @tenant_id;', parameters: QueryParameters.named({'tenant': 1}));
}
''',
    missing: ['tenant_id'],
    lastOccurrence: true,
  ),
  'conditional_query_branches': _Fixture(
    r'''
void example(dynamic session, bool flag) {
  final query = flag ? 'select @id;' : 'select @tenant_id;';
  session.db.unsafeQuery(query, parameters: QueryParameters.named({'id': 1}));
}
''',
    missing: ['tenant_id'],
  ),
};

void main() {
  late Directory directory;
  late ProcessResult result;
  late String output;
  final failures = <String, List<String>>{};

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'sql_parameter_bindings_',
    );
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
    output = '${result.stdout}\n${result.stderr}';
    for (final line in output.split('\n')) {
      final match = RegExp(r'\bFAIL ([^:\s]+)\.dart:').firstMatch(line);
      if (match != null) {
        failures
            .putIfAbsent(match.group(1)!, () => [])
            .add(line.substring(match.start));
      }
    }
  });

  tearDownAll(() async {
    await directory.delete(recursive: true);
  });

  for (final entry in _fixtures.entries) {
    test(entry.key, () {
      final fixture = entry.value;
      final lines = failures[entry.key] ?? [];
      expect(lines, hasLength(fixture.missing.length), reason: output);
      for (final name in fixture.missing) {
        final token = '@$name';
        final offset = fixture.lastOccurrence
            ? fixture.source.lastIndexOf(token)
            : fixture.source.indexOf(token);
        final prefix = fixture.source.substring(0, offset);
        final line = '\n'.allMatches(prefix).length + 1;
        final column =
            prefix.substring(prefix.lastIndexOf('\n') + 1).runes.length + 1;
        expect(
          lines,
          contains(
            allOf(
              contains('${entry.key}.dart:$line:$column'),
              contains('missing named parameter binding for $token '),
              contains('available keys:'),
            ),
          ),
          reason: output,
        );
      }
      if (fixture.skipped) {
        expect(
          output,
          contains('SKIP BINDINGS ${entry.key}.dart:'),
          reason: output,
        );
      } else if (fixture.missing.isEmpty) {
        expect(output, contains('OK ${entry.key}.dart:'), reason: output);
        expect(
          output,
          isNot(contains('SKIP BINDINGS ${entry.key}.dart:')),
          reason: output,
        );
      }
    });
  }

  test(
    'missing bindings cause a nonzero exit code without syntax failures',
    () {
      expect(result.exitCode, 1, reason: output);
      expect(output, contains('0 failed;'), reason: output);
    },
  );
}
