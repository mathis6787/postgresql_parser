import 'package:analyzer/dart/ast/ast.dart';

import 'dart_sources.dart';

/// Values understood by the bounded source evaluator. No Dart code is run.
abstract class StaticValue {}

final class UnknownValue extends StaticValue {
  UnknownValue(this.reason, {this.identity});
  final String reason;
  final String? identity;
}

final class StaticOrigin {
  StaticOrigin(this.file, this.offset);
  final SourceFile file;
  final int offset;
}

final class StaticText {
  StaticText(this.text, this.origins, this.endOrigin);
  factory StaticText.synthetic(String text, SourceFile file, int offset) =>
      StaticText(text, null, StaticOrigin(file, offset));
  final String text;
  final List<StaticOrigin>? origins;
  final StaticOrigin endOrigin;
  StaticText append(StaticText other) {
    if (text.isEmpty) return other;
    if (other.text.isEmpty) return this;
    return StaticText(
      text + other.text,
      origins == null || other.origins == null
          ? null
          : [...origins!, ...other.origins!],
      other.endOrigin,
    );
  }
}

final class TextValue extends StaticValue {
  TextValue(this.text);
  final StaticText text;
}

final class ScalarValue extends StaticValue {
  ScalarValue(this.value);
  final Object? value;
}

final class ListValue extends StaticValue {
  ListValue(this.items);
  final List<StaticValue> items;
  bool known = true;
}

final class MapValue extends StaticValue {
  MapValue(this.entries);
  final Map<String, StaticValue> entries;
  bool known = true;
}

/// Lazy collection views retain their source so later mutations are visible.
final class IterableValue extends StaticValue {
  IterableValue(this.source, this.kind, {this.callback, this.predicate, this.unit});
  final StaticValue source;
  final String kind;
  final FunctionExpression? callback;
  final Expression? predicate;
  final DartUnit? unit;
}

final class MapEntryValue extends StaticValue {
  MapEntryValue(this.key, this.value);
  final StaticValue key;
  final StaticValue value;
}

final class BufferValue extends StaticValue {
  BufferValue(this.text);
  StaticText text;
  bool known = true;
}

final class RecordValue extends StaticValue {
  RecordValue(this.positional, this.named);
  final List<StaticValue> positional;
  final Map<String, StaticValue> named;
}

final class ObjectValue extends StaticValue {
  ObjectValue(this.type, this.fields, {this.exact = true});
  final DartDeclaration type;
  final Map<String, StaticValue> fields;
  final bool exact;
}

final class EnumValue extends StaticValue {
  EnumValue(this.type, this.index, this.name);
  final DartDeclaration type;
  final int index;
  final String name;
}

final class BindingsValue extends StaticValue {
  BindingsValue(this.map);
  final MapValue map;
}

/// Branch snapshots retain alias identity while isolating mutable collections.
final class StaticFrame {
  StaticFrame(
    this.unit, {
    Map<Object, StaticValue>? env,
    Map<String, bool>? conditions,
    Map<AstNode, int>? versions,
    Set<AstNode>? active,
    Set<AstNode>? invalidated,
    this.receiver,
    this.helper = false,
    this.depth = 0,
    this.cascadeTarget,
  }) : env = env ?? {},
       conditions = conditions ?? {},
       versions = versions ?? {},
       active = active ?? {},
       invalidated = invalidated ?? {};
  DartUnit unit;
  // Declaration keys are AST nodes; temporary values use distinct identity
  // keys so nested expressions cannot overwrite an enclosing assembly.
  final Map<Object, StaticValue> env;
  final Map<String, bool> conditions;
  final Map<AstNode, int> versions;
  final Set<AstNode> active;
  final Set<AstNode> invalidated;
  ObjectValue? receiver;
  final bool helper;
  int depth;
  StaticValue? cascadeTarget;
  StaticValue Function(StaticValue)? _cloneValue;
  StaticValue clonedValue(StaticValue value) =>
      _cloneValue?.call(value) ?? value;
  StaticOutcome copyOutcome(StaticValue value, {DartUnit? unit, bool? helper}) {
    final next = copy(unit: unit, helper: helper);
    return StaticOutcome(next.clonedValue(value), next);
  }

  StaticFrame withUnit(DartUnit unit, {bool? helper}) => StaticFrame(
    unit,
    env: env,
    conditions: conditions,
    versions: versions,
    active: active,
    invalidated: invalidated,
    receiver: receiver,
    helper: helper ?? this.helper,
    depth: depth,
    cascadeTarget: cascadeTarget,
  );

  StaticFrame copy({DartUnit? unit, bool? helper}) {
    final copies = <StaticValue, StaticValue>{};
    StaticValue clone(StaticValue value) {
      final prior = copies[value];
      if (prior != null) return prior;
      if (value is ListValue) {
        final result = ListValue([]);
        result.known = value.known;
        copies[value] = result;
        result.items.addAll(value.items.map(clone));
        return result;
      }
      if (value is MapValue) {
        final result = MapValue({});
        result.known = value.known;
        copies[value] = result;
        result.entries.addAll(
          value.entries.map((key, value) => MapEntry(key, clone(value))),
        );
        return result;
      }
      if (value is BufferValue) {
        return copies[value] = BufferValue(value.text)..known = value.known;
      }
      if (value is ObjectValue) {
        final result = ObjectValue(value.type, {}, exact: value.exact);
        copies[value] = result;
        result.fields.addAll(
          value.fields.map((key, value) => MapEntry(key, clone(value))),
        );
        return result;
      }
      if (value is RecordValue) {
        final result = RecordValue([], {});
        copies[value] = result;
        result.positional.addAll(value.positional.map(clone));
        result.named.addAll(
          value.named.map((key, value) => MapEntry(key, clone(value))),
        );
        return result;
      }
      if (value is BindingsValue) {
        return copies[value] = BindingsValue(clone(value.map) as MapValue);
      }
      if (value is IterableValue) {
        return copies[value] = IterableValue(
          clone(value.source),
          value.kind,
          callback: value.callback,
          predicate: value.predicate,
          unit: value.unit,
        );
      }
      if (value is MapEntryValue) {
        return copies[value] = MapEntryValue(
          clone(value.key),
          clone(value.value),
        );
      }
      return value;
    }

    final result = StaticFrame(
      unit ?? this.unit,
      env: env.map((key, value) => MapEntry(key, clone(value))),
      conditions: {...conditions},
      versions: {...versions},
      active: {...active},
      invalidated: {...invalidated},
      depth: depth,
      helper: helper ?? this.helper,
    );
    final current = receiver;
    result.receiver = current == null ? null : clone(current) as ObjectValue;
    result.cascadeTarget = cascadeTarget == null ? null : clone(cascadeTarget!);
    result._cloneValue = clone;
    return result;
  }

  /// Joins branch observations only when all stored values and mutable aliases
  /// are equivalent. Differing mutations must remain separate paths.
  static StaticFrame? joinEquivalent(List<StaticFrame> frames) {
    if (frames.isEmpty) return null;
    final first = frames.first;
    for (final other in frames.skip(1)) {
      if (!identical(first.unit, other.unit) ||
          first.helper != other.helper ||
          first.env.length != other.env.length ||
          first.active.length != other.active.length ||
          !first.active.every(other.active.contains)) {
        return null;
      }
      final pairs = <StaticValue, StaticValue>{};
      final reverse = <StaticValue, StaticValue>{};
      for (final binding in first.env.entries) {
        final value = other.env[binding.key];
        if (value == null ||
            !_equivalentValue(binding.value, value, pairs, reverse)) {
          return null;
        }
      }
      for (final values in [
        (first.receiver, other.receiver),
        (first.cascadeTarget, other.cascadeTarget),
      ]) {
        if (values.$1 == null || values.$2 == null) {
          if (values.$1 != null || values.$2 != null) return null;
        } else if (!_equivalentValue(values.$1!, values.$2!, pairs, reverse)) {
          return null;
        }
      }
    }
    final joined = first.copy();
    joined.conditions.removeWhere(
      (key, value) =>
          frames.skip(1).any((frame) => frame.conditions[key] != value),
    );
    for (final frame in frames.skip(1)) {
      if (frame.depth > joined.depth) joined.depth = frame.depth;
      joined.invalidated.addAll(frame.invalidated);
      for (final version in frame.versions.entries) {
        final current = joined.versions[version.key] ?? 0;
        if (version.value > current) {
          joined.versions[version.key] = version.value;
        }
      }
    }
    return joined;
  }
}

bool equivalentStaticValues(StaticValue first, StaticValue second) =>
    _equivalentValue(first, second, {}, {});

bool _equivalentValue(
  StaticValue first,
  StaticValue second,
  Map<StaticValue, StaticValue> pairs,
  Map<StaticValue, StaticValue> reverse,
) {
  if (first.runtimeType != second.runtimeType) return false;
  if (first is TextValue && second is TextValue) {
    return first.text.text == second.text.text;
  }
  if (first is ScalarValue && second is ScalarValue) {
    final a = first.value;
    final b = second.value;
    return a.runtimeType == b.runtimeType &&
        a == b &&
        (a is! double || b is double && a.isNegative == b.isNegative);
  }
  if (first is UnknownValue && second is UnknownValue) {
    return first.identity == second.identity && first.reason == second.reason;
  }
  if (first is EnumValue && second is EnumValue) {
    return identical(first.type.node, second.type.node) &&
        first.index == second.index;
  }
  final prior = pairs[first];
  if (prior != null) return identical(prior, second);
  if (reverse.containsKey(second)) return false;
  pairs[first] = second;
  reverse[second] = first;
  bool same(StaticValue a, StaticValue b) =>
      _equivalentValue(a, b, pairs, reverse);
  bool list(List<StaticValue> a, List<StaticValue> b) =>
      a.length == b.length &&
      List.generate(
        a.length,
        (index) => index,
      ).every((index) => same(a[index], b[index]));
  bool map(Map<String, StaticValue> a, Map<String, StaticValue> b) =>
      a.length == b.length &&
      a.entries.every(
        (entry) => b.containsKey(entry.key) && same(entry.value, b[entry.key]!),
      );
  if (first is ListValue && second is ListValue) {
    return first.known == second.known && list(first.items, second.items);
  }
  if (first is MapValue && second is MapValue) {
    return first.known == second.known && map(first.entries, second.entries);
  }
  if (first is BufferValue && second is BufferValue) {
    return first.known == second.known && first.text.text == second.text.text;
  }
  if (first is RecordValue && second is RecordValue) {
    return list(first.positional, second.positional) &&
        map(first.named, second.named);
  }
  if (first is ObjectValue && second is ObjectValue) {
    return identical(first.type.node, second.type.node) &&
        first.exact == second.exact &&
        map(first.fields, second.fields);
  }
  if (first is IterableValue && second is IterableValue) {
    return first.kind == second.kind &&
        identical(first.callback, second.callback) &&
        identical(first.predicate, second.predicate) &&
        identical(first.unit, second.unit) &&
        same(first.source, second.source);
  }
  if (first is MapEntryValue && second is MapEntryValue) {
    return same(first.key, second.key) && same(first.value, second.value);
  }
  if (first is BindingsValue && second is BindingsValue) {
    return same(first.map, second.map);
  }
  return identical(first, second);
}

final class StaticOutcome {
  StaticOutcome(this.value, this.frame);
  final StaticValue value;
  final StaticFrame frame;
}

abstract interface class StaticRuntime {
  List<StaticOutcome> evaluate(Expression expression, StaticFrame frame);
  List<StaticOutcome> invokeCallable(
    DartDeclaration target,
    ArgumentList arguments,
    StaticFrame caller, {
    ObjectValue? receiver,
  });
}

abstract interface class StaticObjects {
  List<StaticOutcome>? evaluate(
    Expression expression,
    StaticFrame frame,
    StaticRuntime runtime,
  );
  List<StaticOutcome>? property(
    StaticValue receiver,
    String name,
    StaticFrame frame,
    StaticRuntime runtime,
  );
  List<StaticOutcome>? method(
    StaticValue receiver,
    MethodInvocation call,
    StaticFrame frame,
    StaticRuntime runtime,
  );
}
