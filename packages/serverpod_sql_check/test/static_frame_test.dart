import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';

import '../lib/src/dart_sources.dart';
import '../lib/src/static_contexts.dart';
import '../lib/src/static_demand.dart';
import '../lib/src/static_evaluator.dart';
import '../lib/src/static_objects.dart';
import '../lib/src/static_value.dart';

void main() {
  late DartUnit unit;
  late DartDeclaration type;
  late AstNode firstNode;
  late AstNode secondNode;
  late Object firstKey;
  late Object secondKey;

  setUp(() {
    unit = DartSources().unitFor(
      '/private/tmp/static_frame_fixture.dart',
      content: 'class Box {} var first = 0, second = 0;',
    );
    type = DartDeclaration(unit, unit.unit.declarations.first);
    final variables =
        (unit.unit.declarations.last as TopLevelVariableDeclaration)
            .variables
            .variables;
    firstNode = variables.first;
    secondNode = variables.last;
    firstKey = Object();
    secondKey = Object();
  });

  MapValue map() => MapValue({'id': ScalarValue(1)});
  TextValue text(String value) =>
      TextValue(StaticText.synthetic(value, unit, 0));

  group('equivalent static values', () {
    test('number type and signed zero remain distinct', () {
      expect(equivalentStaticValues(ScalarValue(1), ScalarValue(1.0)), isFalse);
      expect(
        equivalentStaticValues(ScalarValue(0.0), ScalarValue(-0.0)),
        isFalse,
      );
      expect(
        equivalentStaticValues(ScalarValue(-0.0), ScalarValue(-0.0)),
        isTrue,
      );
      expect(
        equivalentStaticValues(
          ScalarValue(double.nan),
          ScalarValue(double.nan),
        ),
        isFalse,
      );
      expect(
        equivalentStaticValues(ScalarValue(null), ScalarValue(null)),
        isTrue,
      );
    });

    test('invalidated collection contents never equal known contents', () {
      expect(equivalentStaticValues(map(), map()..known = false), isFalse);
      expect(
        equivalentStaticValues(
          ListValue([text('select 1')]),
          ListValue([text('select 1')])..known = false,
        ),
        isFalse,
      );
      expect(
        equivalentStaticValues(
          BufferValue(text('select 1').text),
          BufferValue(text('select 1').text)..known = false,
        ),
        isFalse,
      );
    });

    test(
      'unknown observation identities and exact receivers remain distinct',
      () {
        expect(
          equivalentStaticValues(
            UnknownValue('input', identity: 'first'),
            UnknownValue('input', identity: 'second'),
          ),
          isFalse,
        );
        expect(
          equivalentStaticValues(
            ObjectValue(type, {}),
            ObjectValue(type, {}, exact: false),
          ),
          isFalse,
        );
      },
    );

    test('bidirectional correspondence rejects different nested aliases', () {
      final shared = map();
      final aliased = RecordValue([shared, shared], {});
      final distinct = RecordValue([map(), map()], {});
      expect(equivalentStaticValues(aliased, distinct), isFalse);
      expect(equivalentStaticValues(distinct, aliased), isFalse);
    });

    test('cyclic maps compare their complete topology and contents', () {
      final left = map();
      left.entries['self'] = left;
      final right = map();
      right.entries['self'] = right;
      expect(equivalentStaticValues(left, right), isTrue);
      right.entries['id'] = ScalarValue(2);
      expect(equivalentStaticValues(left, right), isFalse);
      final nested = map();
      final child = map();
      nested.entries['self'] = child;
      child.entries['self'] = child;
      expect(equivalentStaticValues(left, nested), isFalse);
    });

    test('lazy collection views retain callback, source alias, and kind', () {
      final source = map();
      final values = IterableValue(source, 'values');
      final entries = IterableValue(source, 'entries');
      expect(equivalentStaticValues(values, entries), isFalse);
      expect(
        equivalentStaticValues(
          RecordValue([source, values], {}),
          RecordValue([map(), IterableValue(map(), 'values')], {}),
        ),
        isFalse,
      );
    });
  });

  group('static frame branch joins', () {
    test('equivalent clones preserve aliases and isolate later mutations', () {
      final shared = map();
      final frame = StaticFrame(
        unit,
        env: {firstKey: shared, secondKey: shared},
      );
      final other = frame.copy();
      final joined = StaticFrame.joinEquivalent([frame, other])!;
      final first = joined.env[firstKey] as MapValue;
      final second = joined.env[secondKey] as MapValue;
      expect(identical(first, second), isTrue);
      expect(identical(first, shared), isFalse);
      first.entries.clear();
      expect(second.entries, isEmpty);
      expect(shared.entries.keys, contains('id'));
      expect((other.env[firstKey] as MapValue).entries.keys, contains('id'));
    });

    test('different alias topology rejects the join in either order', () {
      final shared = map();
      final aliased = StaticFrame(
        unit,
        env: {firstKey: shared, secondKey: shared},
      );
      final distinct = StaticFrame(
        unit,
        env: {firstKey: map(), secondKey: map()},
      );
      expect(StaticFrame.joinEquivalent([aliased, distinct]), isNull);
      expect(StaticFrame.joinEquivalent([distinct, aliased]), isNull);
    });

    test(
      'different mutations and different environment keys remain separate',
      () {
        final frame = StaticFrame(unit, env: {firstKey: map()});
        final changed = frame.copy();
        (changed.env[firstKey] as MapValue).entries.clear();
        expect(StaticFrame.joinEquivalent([frame, changed]), isNull);
        expect(
          StaticFrame.joinEquivalent([
            frame,
            StaticFrame(unit, env: {secondKey: map()}),
          ]),
          isNull,
        );
      },
    );

    test('receiver aliases participate in the environment correspondence', () {
      final shared = map();
      final frame = StaticFrame(
        unit,
        env: {firstKey: shared},
        receiver: ObjectValue(type, {'parameters': shared}),
      );
      final joined = StaticFrame.joinEquivalent([frame, frame.copy()])!;
      expect(
        identical(joined.env[firstKey], joined.receiver!.fields['parameters']),
        isTrue,
      );
      final wrong = StaticFrame(
        unit,
        env: {firstKey: map()},
        receiver: ObjectValue(type, {'parameters': map()}),
      );
      expect(StaticFrame.joinEquivalent([frame, wrong]), isNull);
      expect(
        StaticFrame.joinEquivalent([
          frame,
          StaticFrame(unit, env: {firstKey: map()}),
        ]),
        isNull,
      );
    });

    test('cascade aliases participate in the environment correspondence', () {
      final shared = map();
      final frame = StaticFrame(
        unit,
        env: {firstKey: shared},
        cascadeTarget: shared,
      );
      final joined = StaticFrame.joinEquivalent([frame, frame.copy()])!;
      expect(identical(joined.env[firstKey], joined.cascadeTarget), isTrue);
      final wrong = StaticFrame(
        unit,
        env: {firstKey: map()},
        cascadeTarget: map(),
      );
      expect(StaticFrame.joinEquivalent([frame, wrong]), isNull);
    });

    test('joins cyclic maps without retaining either branch instance', () {
      final shared = map();
      shared.entries['self'] = shared;
      final frame = StaticFrame(unit, env: {firstKey: shared});
      final joined = StaticFrame.joinEquivalent([frame, frame.copy()])!;
      final cyclic = joined.env[firstKey] as MapValue;
      expect(identical(cyclic.entries['self'], cyclic), isTrue);
      expect(identical(cyclic, shared), isFalse);
    });

    test('cyclic record/map clones retain the same record alias on joins', () {
      final contents = map();
      final record = RecordValue([], {'contents': contents});
      contents.entries['record'] = record;
      final frame = StaticFrame(unit, env: {firstKey: record});
      final copy = frame.copy();
      final copiedRecord = copy.env[firstKey] as RecordValue;
      final copiedMap = copiedRecord.named['contents'] as MapValue;
      expect(identical(copiedMap.entries['record'], copiedRecord), isTrue);
      final joined = StaticFrame.joinEquivalent([frame, copy])!;
      final joinedRecord = joined.env[firstKey] as RecordValue;
      expect(
        identical(
          (joinedRecord.named['contents'] as MapValue).entries['record'],
          joinedRecord,
        ),
        isTrue,
      );
      expect(identical(joinedRecord, record), isFalse);
    });

    test('retains only common observations and unions invalidation', () {
      final first = StaticFrame(
        unit,
        conditions: {'common': true, 'opposite': false, 'first': true},
        invalidated: {firstNode},
        versions: {firstNode: 1},
      );
      final second = StaticFrame(
        unit,
        conditions: {'common': true, 'opposite': true, 'second': false},
        invalidated: {secondNode},
        versions: {firstNode: 3, secondNode: 2},
      );
      final joined = StaticFrame.joinEquivalent([first, second])!;
      expect(joined.conditions, {'common': true});
      expect(joined.invalidated, {firstNode, secondNode});
      expect(joined.versions, {firstNode: 3, secondNode: 2});
      expect(first.conditions.keys, contains('first'));
      expect(first.invalidated, {firstNode});
      expect(second.invalidated, {secondNode});
    });

    test('unit, helper mode, and active recursion scope remain separate', () {
      final frame = StaticFrame(unit, active: {firstNode});
      final secondUnit = DartSources().unitFor(
        '/private/tmp/static_frame_other.dart',
        content: '',
      );
      expect(
        StaticFrame.joinEquivalent([
          frame,
          StaticFrame(secondUnit, active: {firstNode}),
        ]),
        isNull,
      );
      expect(
        StaticFrame.joinEquivalent([
          frame,
          StaticFrame(unit, helper: true, active: {firstNode}),
        ]),
        isNull,
      );
      expect(
        StaticFrame.joinEquivalent([
          frame,
          StaticFrame(unit, active: {secondNode}),
        ]),
        isNull,
      );
      expect(StaticFrame.joinEquivalent([]), isNull);
    });

    test(
      'preserves the greatest evaluation depth from equivalent branches',
      () {
        final shallow = StaticFrame(unit, depth: 1);
        final deep = StaticFrame(unit, depth: 31);
        expect(StaticFrame.joinEquivalent([shallow, deep])!.depth, 31);
        expect(StaticFrame.joinEquivalent([deep, shallow])!.depth, 31);
      },
    );
  });

  group('receiver field snapshot restoration', () {
    StaticEvaluator evaluator(SourceObjects objects) => StaticEvaluator(
      objects: objects,
      mapText: (text, unit, start, end, raw) =>
          StaticText.synthetic(text, unit, start),
    );

    test('helper on another instance restores the original receiver field', () {
      final source = DartSources().unitFor(
        '/private/tmp/receiver_snapshot.dart',
        content: '''
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
void example(dynamic session) { session.unsafeQuery(Builder('select from;').outer()); }
''',
      );
      final function = source.unit.declarations.last as FunctionDeclaration;
      final statement =
          (function.functionExpression.body as BlockFunctionBody)
                  .block
                  .statements
                  .single
              as ExpressionStatement;
      final call = statement.expression as MethodInvocation;
      final runtime = evaluator(SourceObjects());
      final outcomes = [
        for (final frame in runtime.framesAt(call, source))
          ...runtime.evaluate(
            call.argumentList.arguments.single.argumentExpression,
            frame,
          ),
      ];
      expect(outcomes, hasLength(1));
      expect((outcomes.single.value as TextValue).text.text, 'select from;');
    });

    test(
      'context field seeding cannot capture another instance helper fields',
      () {
        final source = DartSources().unitFor(
          '/private/tmp/partial_snapshot.dart',
          content: '''
class Builder {
  final String _sql;
  Builder(this._sql);
  String getSql() => _sql;
  String _build() {
    Builder('select 1').getSql();
    return _sql;
  }
  void example(dynamic session) { session.unsafeQuery(_build()); }
}
''',
        );
        final owner = source.unit.declarations.single as ClassDeclaration;
        final function = owner.body.members.last as MethodDeclaration;
        final statement =
            (function.body as BlockFunctionBody).block.statements.single
                as ExpressionStatement;
        final call = statement.expression as MethodInvocation;
        final objects = SourceObjects();
        final runtime = evaluator(objects);
        final contexts = StaticContexts(source, runtime, objects);
        final outcomes = [
          for (final frame in contexts.framesAt(call))
            ...runtime.evaluate(
              call.argumentList.arguments.single.argumentExpression,
              frame,
            ),
        ];
        expect(outcomes, hasLength(1));
        expect(outcomes.single.value, isA<UnknownValue>());
      },
    );
    test(
      'partial receiver rejects an unknown mixin override on a local subclass',
      () {
        final source = DartSources().unitFor(
          '/private/tmp/mixin_snapshot.dart',
          content: '''
final class Queries {
  String build() => 'select 1';
  void example(dynamic session) { session.unsafeQuery(build()); }
}
final class Other extends Queries with UnknownMixin {}
''',
        );
        final owner = source.unit.declarations.first as ClassDeclaration;
        final function = owner.body.members.last as MethodDeclaration;
        final statement =
            (function.body as BlockFunctionBody).block.statements.single
                as ExpressionStatement;
        final call = statement.expression as MethodInvocation;
        final objects = SourceObjects();
        final runtime = evaluator(objects);
        final contexts = StaticContexts(source, runtime, objects);
        final outcomes = [
          for (final frame in contexts.framesAt(call))
            ...runtime.evaluate(
              call.argumentList.arguments.single.argumentExpression,
              frame,
            ),
        ];
        expect(outcomes, hasLength(1));
        expect(outcomes.single.value, isA<UnknownValue>());
      },
    );
  });

  for (final helper in {
    'direct': 'Map<String, int> alias() => params;',
    'nested': 'Map<String, int> inner() => params; Map<String, int> alias() => inner();',
  }.entries) {
    test(
      'discarded ${helper.key} helper-return aliases remain visible to later escapes',
      () {
        final source = DartSources().unitFor(
          '/private/tmp/demand_alias_snapshot.dart',
          content:
              '''
void example(dynamic session) {
  final params = {'id': 1};
  ${helper.value}
  final hidden = {'obj': alias()};
  consume(hidden);
  session.unsafeQuery('select @id', parameters: QueryParameters.named(params));
}
''',
        );
        final function = source.unit.declarations.single as FunctionDeclaration;
        final call =
            ((function.functionExpression.body as BlockFunctionBody)
                            .block
                            .statements
                            .last
                        as ExpressionStatement)
                    .expression
                as MethodInvocation;
        final sql = call.argumentList.arguments.first.argumentExpression;
        final parameters = call.argumentList.arguments.last.argumentExpression;
        final demand = StaticDemand(sql, parameters, source);
        final runtime = StaticEvaluator(
          objects: SourceObjects(),
          mapText: (text, unit, start, end, raw) =>
              StaticText.synthetic(text, unit, start),
        );
        final outcomes = [
          for (final frame in runtime.framesAt(
            call,
            source,
            needed: demand.needed,
            keysOnly: demand.keysOnly,
          ))
            ...runtime.evaluate(parameters, frame),
        ];
        expect(outcomes, hasLength(1));
        expect((outcomes.single.value as BindingsValue).map.known, isFalse);
      },
    );
  }
}
