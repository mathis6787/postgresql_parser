import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'dart_sources.dart';
import 'static_value.dart';
import 'static_conditions.dart';

/// A bounded, source-only interpreter for readable query construction.
///
/// Unknown values are carried through the flow, rather than silently dropping
/// paths. Mutable collection aliases share identity inside a path; each branch
/// gets an independent copy. No application Dart code is executed.
final class StaticEvaluator implements StaticRuntime {
  StaticEvaluator({required this.mapText, required this.objects});

  final StaticText Function(String, DartUnit, int, int, bool) mapText;
  final StaticObjects objects;
  static const limit = 32;
  final _astFacts = Expando<_AstFacts>();
  final _rootTargets =
      <(AstNode, DartUnit), List<({Expression expression, AstNode? target})>>{};
  final _capturedTargets = <(AstNode, DartUnit), Set<AstNode>>{};
  final _callbackReadable = <(FunctionExpression, DartUnit, int), bool>{};
  final _helperDeclarations = <(AstNode, DartUnit), List<DartDeclaration>>{};

  _AstFacts _facts(AstNode node) => _astFacts[node] ??= _AstFacts(node);

  List<({Expression expression, AstNode? target})> _references(
    AstNode node,
    DartUnit unit,
  ) => _rootTargets.putIfAbsent(
    (node, unit),
    () => [
      for (final expression in _facts(node).roots.expressions)
        (
          expression: expression,
          target: unit.sources.resolve(expression, unit)?.node,
        ),
    ],
  );

  Set<AstNode> _captures(AstNode node, DartUnit unit) => _capturedTargets
      .putIfAbsent((node, unit), () => _facts(node).captured.targets(unit));

  List<DartDeclaration> _helpers(AstNode node, DartUnit unit) =>
      _helperDeclarations.putIfAbsent(
        (node, unit),
        () => [
          for (final call in {
            ..._facts(node).calls.expressions,
            ..._facts(node).roots.expressions,
          })
            if (unit.sources.resolve(call, unit) case final declaration?)
              if (declaration.unit.readable &&
                  (declaration.node is FunctionDeclaration ||
                      declaration.node is MethodDeclaration ||
                      declaration.node is ConstructorDeclaration))
                declaration,
        ],
      );

  List<StaticFrame> framesAt(
    AstNode use,
    DartUnit unit, {
    StaticFrame? initial,
    Set<AstNode>? needed,
    Set<AstNode>? keysOnly,
  }) {
    if (!unit.readable) return [];
    Block? block;
    for (AstNode? owner = use.parent; owner != null; owner = owner.parent) {
      if (owner is BlockFunctionBody) {
        block = owner.block;
        break;
      }
      if (owner is ExpressionFunctionBody) break;
    }
    final frame = initial ?? StaticFrame(unit);
    frame.unit = unit;
    if (block == null) return [frame];
    frame.invalidated.addAll(_captures(block, unit));
    final flow = _statement(
      block,
      [_Flow(frame)],
      stop: use,
      needed: needed,
      keysOnly: keysOnly,
    );
    return flow
        .where((value) => value.kind == _FlowKind.reached)
        .map((value) => value.frame)
        .toList();
  }

  @override
  List<StaticOutcome> evaluate(Expression expression, StaticFrame frame) {
    if (!frame.unit.readable || frame.depth >= limit) {
      return [_unknown(frame, 'evaluation limit')];
    }
    final depth = frame.depth;
    frame.depth = depth + 1;
    try {
      final result = _evaluate(expression, frame);
      for (final outcome in result) {
        outcome.frame.depth = depth;
      }
      return result;
    } finally {
      frame.depth = depth;
    }
  }

  List<StaticOutcome> _evaluate(Expression expression, StaticFrame frame) {
    final unit = frame.unit;
    if (expression is ParenthesizedExpression) {
      return [
        for (final value in evaluate(expression.expression, frame))
          StaticOutcome(_chainValue(value.value), value.frame),
      ];
    }
    if (expression is AsExpression) {
      return evaluate(expression.expression, frame);
    }
    if (expression is AwaitExpression) {
      return [
        for (final value in evaluate(expression.expression, frame))
          _unknown(value.frame, 'asynchronous value'),
      ];
    }
    if (expression is SimpleStringLiteral) {
      return [
        StaticOutcome(
          TextValue(
            mapText(
              expression.value,
              unit,
              expression.contentsOffset,
              expression.contentsEnd,
              expression.isRaw,
            ),
          ),
          frame,
        ),
      ];
    }
    if (expression is IntegerLiteral) return [_scalar(expression.value, frame)];
    if (expression is DoubleLiteral) return [_scalar(expression.value, frame)];
    if (expression is BooleanLiteral) return [_scalar(expression.value, frame)];
    if (expression is NullLiteral) return [_scalar(null, frame)];
    if (expression is ThisExpression) {
      return [
        StaticOutcome(
          frame.receiver ?? UnknownValue('unknown receiver'),
          frame,
        ),
      ];
    }
    if (expression is SimpleIdentifier ||
        expression is PrefixedIdentifier ||
        expression is PropertyAccess) {
      final declaration = unit.sources.resolve(expression, unit);
      if (declaration != null) {
        final node = declaration.node;
        if (node is FunctionDeclaration && !node.isGetter ||
            node is MethodDeclaration && node.propertyKeyword == null) {
          // A function value can return or expose captured aliases when an
          // unknown consumer invokes it. No callable value model is retained.
          _invalidateStatement(expression, frame);
          return [_unknown(frame, 'unreadable function value')];
        }
        if (frame.invalidated.contains(node)) {
          return [_unknown(frame, 'captured mutation')];
        }
        if (node is FormalParameter &&
            (!frame.env.containsKey(node) || frame.env[node] is UnknownValue)) {
          final finite = _finiteParameter(declaration, frame);
          if (finite != null) return finite;
        }
        if (frame.env.containsKey(node)) {
          return [StaticOutcome(frame.env[node]!, frame)];
        }
        if (node is VariableDeclaration) {
          final list = node.parent;
          final field = list?.parent;
          if (field is FieldDeclaration &&
              !field.isStatic &&
              frame.receiver == null) {
            return [_unknown(frame, 'unknown instance field dispatch')];
          }
          if (list is! VariableDeclarationList ||
              list.isLate ||
              (!list.isConst && !list.isFinal) ||
              node.initializer == null ||
              !frame.active.add(node)) {
            return [_unknown(frame, 'unreadable variable')];
          }
          try {
            final next = frame.withUnit(declaration.unit);
            final values = evaluate(node.initializer!, next);
            for (final result in values) {
              // Constant declarations may be shared. Mutable global containers
              // can escape anywhere in the application and are left unknown.
              final value = result.value;
              result.frame.env[node] =
                  !list.isConst &&
                      (list.parent is TopLevelVariableDeclaration ||
                          field is FieldDeclaration && field.isStatic)
                  ? _sharedValue(value)
                  : value;

              result.frame.active.remove(node);
            }
            return [
              for (final result in values)
                StaticOutcome(
                  result.frame.env[node]!,
                  result.frame.withUnit(unit),
                ),
            ];
          } finally {
            frame.active.remove(node);
          }
        }
      }
      final delegated = objects.evaluate(expression, frame, this);
      if (delegated != null) return delegated;
      if (expression is PrefixedIdentifier) {
        return _property(expression.prefix, expression.identifier.name, frame);
      }
      if (expression is PropertyAccess && expression.target != null) {
        return _property(
          expression.target!,
          expression.propertyName.name,
          frame,
          nullAware: expression.isNullAware,
        );
      }
      return [
        _unknown(
          frame,
          'unresolved value',
          identity: _identity(expression, frame),
        ),
      ];
    }
    if (expression is ConditionalExpression) {
      final result = <StaticOutcome>[];
      for (final branch in _branches(expression.condition, frame)) {
        result.addAll(
          evaluate(
            branch.truth
                ? expression.thenExpression
                : expression.elseExpression,
            branch.frame,
          ),
        );
      }
      return _bounded(result, frame);
    }
    if (expression is BinaryExpression) {
      if (expression.operator.lexeme == '&&' ||
          expression.operator.lexeme == '||') {
        return [
          for (final branch in _branches(expression, frame))
            _scalar(branch.truth, branch.frame),
        ];
      }
      final result = <StaticOutcome>[];
      final anchor = Object();
      for (final left in evaluate(expression.leftOperand, frame)) {
        if (expression.operator.lexeme == '??' &&
            left.value is! UnknownValue &&
            left.value is! _SkippedNullValue &&
            !(left.value is ScalarValue &&
                (left.value as ScalarValue).value == null)) {
          result.add(left);
          continue;
        }
        left.frame.env[anchor] = left.value;
        for (final right in evaluate(expression.rightOperand, left.frame)) {
          result.add(
            StaticOutcome(
              _binary(
                expression.operator.lexeme,
                right.frame.env[anchor] ?? UnknownValue('unknown left operand'),
                right.value,
                expression,
                right.frame,
              ),
              right.frame,
            ),
          );
        }
      }
      for (final outcome in result) {
        outcome.frame.env.remove(anchor);
      }
      frame.env.remove(anchor);
      return _bounded(result, frame);
    }
    if (expression is PrefixExpression) {
      if (expression.operator.lexeme == '++' ||
          expression.operator.lexeme == '--') {
        return _increment(
          expression.operand,
          expression.operator.lexeme,
          frame,
          false,
        );
      }
      return [
        for (final value in evaluate(expression.operand, frame))
          StaticOutcome(
            _prefix(expression.operator.lexeme, value.value),
            value.frame,
          ),
      ];
    }
    if (expression is PostfixExpression && expression.operator.lexeme == '!') {
      return [
        for (final value in evaluate(expression.operand, frame))
          value.value is ScalarValue &&
                  (value.value as ScalarValue).value == null
              ? _unknown(value.frame, 'null assertion')
              : value,
      ];
    }
    if (expression is PostfixExpression) {
      return _increment(
        expression.operand,
        expression.operator.lexeme,
        frame,
        true,
      );
    }
    if (expression is StringInterpolation || expression is AdjacentStrings) {
      var values = [StaticOutcome(TextValue(_empty(expression, frame)), frame)];
      if (expression is AdjacentStrings) {
        for (final part in expression.strings) {
          values = _append(
            values,
            (state) => evaluate(part, state),
            expression,
          );
        }
      } else {
        for (final part in (expression as StringInterpolation).elements) {
          values = _append(
            values,
            (state) => part is InterpolationString
                ? [
                    StaticOutcome(
                      TextValue(
                        mapText(
                          part.value,
                          state.unit,
                          part.contentsOffset,
                          part.contentsEnd,
                          false,
                        ),
                      ),
                      state,
                    ),
                  ]
                : [
                    for (final value in evaluate(
                      (part as InterpolationExpression).expression,
                      state,
                    ))
                      StaticOutcome(
                        _asText(value.value, expression, value.frame),
                        value.frame,
                      ),
                  ],
            expression,
          );
        }
      }
      return _bounded(values, frame);
    }
    if (expression is ListLiteral) {
      return _collection(expression.elements, frame, false);
    }
    if (expression is SetOrMapLiteral) {
      // Empty literals in parameter contexts are maps. Set values are not used
      // as SQL fragments; a set containing expressions remains unknown.
      return _collection(expression.elements, frame, true);
    }
    if (expression is IndexExpression && expression.target != null) {
      final anchor = Object();
      final results = <StaticOutcome>[];
      for (final target in evaluate(expression.target!, frame)) {
        if (target.value is _SkippedNullValue ||
            expression.isNullAware &&
                target.value is ScalarValue &&
                (target.value as ScalarValue).value == null) {
          results.add(StaticOutcome(_SkippedNullValue(), target.frame));
          continue;
        }
        target.frame.env[anchor] = target.value;
        for (final index in evaluate(expression.index, target.frame)) {
          final value = index.frame.env[anchor]!;
          final key = index.value;
          if (value is ListValue &&
              value.known &&
              key is ScalarValue &&
              key.value is int &&
              (key.value as int) >= 0 &&
              (key.value as int) < value.items.length) {
            results.add(
              StaticOutcome(value.items[key.value as int], index.frame),
            );
          } else if (value is MapValue && value.known && key is TextValue) {
            results.add(
              StaticOutcome(
                value.entries[key.text.text] ?? ScalarValue(null),
                index.frame,
              ),
            );
          } else {
            results.add(_unknown(index.frame, 'unknown indexed value'));
          }
        }
      }
      for (final value in results) {
        value.frame.env.remove(anchor);
      }
      frame.env.remove(anchor);
      return _bounded(results, frame);
    }
    if (expression is AssignmentExpression) return _assign(expression, frame);
    if (expression is MethodInvocation) return _method(expression, frame);
    if (expression is InstanceCreationExpression) {
      final name = expression.constructorName.toSource();
      final coreCopy = expression.constructorName.type.importPrefix == null
          ? _copyConstructor(
              expression.constructorName.type.name.lexeme,
              expression.constructorName.name?.name ?? '',
              expression.argumentList,
              expression,
              frame,
            )
          : null;
      if (coreCopy != null) return coreCopy;
      if (name == 'StringBuffer' && _coreStringBuffer(expression, frame)) {
        final arguments = expression.argumentList.arguments;
        if (arguments.isEmpty) {
          return [StaticOutcome(BufferValue(_empty(expression, frame)), frame)];
        }
        if (arguments.length == 1) {
          return [
            for (final value in evaluate(
              arguments.single.argumentExpression,
              frame,
            ))
              StaticOutcome(
                _bufferValue(value.value, expression, value.frame),
                value.frame,
              ),
          ];
        }
      }
      if (_namedParameters(name)) {
        return _bindings(expression.argumentList, frame);
      }
      return objects.evaluate(expression, frame, this) ??
          _unknownCall(expression.argumentList, frame);
    }
    if (expression is SwitchExpression) {
      return _switchExpression(expression, frame);
    }
    if (expression is CascadeExpression) {
      final results = <StaticOutcome>[];
      final anchor = Object();
      for (final target in evaluate(expression.target, frame)) {
        if (expression.isNullAware &&
            target.value is ScalarValue &&
            (target.value as ScalarValue).value == null) {
          results.add(target);
          continue;
        }
        target.frame.env[anchor] = target.value;
        var outcomes = [target];
        for (final section in expression.cascadeSections) {
          final next = <StaticOutcome>[];
          for (final outcome in outcomes) {
            outcome.frame.cascadeTarget = outcome.frame.env[anchor];
            for (final value in evaluate(section, outcome.frame)) {
              next.add(
                StaticOutcome(
                  value.frame.env[anchor] ?? UnknownValue('unknown cascade'),
                  value.frame,
                ),
              );
            }
          }
          outcomes = _bounded(next, frame);
        }
        for (final value in outcomes) {
          value.frame.cascadeTarget = null;
          value.frame.env.remove(anchor);
        }
        results.addAll(outcomes);
      }
      frame.env.remove(anchor);
      return _bounded(results, frame);
    }
    final delegated = objects.evaluate(expression, frame, this);
    if (delegated != null) return delegated;
    _invalidateStatement(expression, frame);
    return [_unknown(frame, 'unsupported expression')];
  }

  List<StaticOutcome> _property(
    Expression target,
    String name,
    StaticFrame frame, {
    bool nullAware = false,
  }) {
    final result = <StaticOutcome>[];
    for (final outcome in evaluate(target, frame)) {
      final value = outcome.value;
      if (value is _SkippedNullValue ||
          nullAware && value is ScalarValue && value.value == null) {
        result.add(StaticOutcome(_SkippedNullValue(), outcome.frame));
      } else if (value is MapEntryValue && (name == 'key' || name == 'value')) {
        result.add(
          StaticOutcome(name == 'key' ? value.key : value.value, outcome.frame),
        );
      } else if (value is MapValue &&
          const {'keys', 'values', 'entries'}.contains(name)) {
        result.add(StaticOutcome(IterableValue(value, name), outcome.frame));
      } else if (value is IterableValue &&
          const {
            'length',
            'isEmpty',
            'isNotEmpty',
            'first',
            'last',
            'single',
          }.contains(name)) {
        result.addAll(_iterableProperty(value, name, outcome.frame));
      } else if ((value is ListValue && !value.known ||
              value is MapValue && !value.known) &&
          const {'length', 'isEmpty', 'isNotEmpty'}.contains(name)) {
        result.add(_unknown(outcome.frame, 'unknown collection size'));
      } else if (value is ListValue &&
          const {'first', 'last', 'single'}.contains(name)) {
        result.add(
          StaticOutcome(_collectionProperty(value, name), outcome.frame),
        );
      } else if (name == 'length' && value is ListValue) {
        result.add(_scalar(value.items.length, outcome.frame));
      } else if (name == 'length' && value is MapValue) {
        result.add(_scalar(value.entries.length, outcome.frame));
      } else if (value is BufferValue &&
          const {'length', 'isEmpty', 'isNotEmpty'}.contains(name)) {
        result.add(
          StaticOutcome(
            value.known
                ? ScalarValue(
                    name == 'length'
                        ? value.text.text.length
                        : name == 'isEmpty'
                        ? value.text.text.isEmpty
                        : value.text.text.isNotEmpty,
                  )
                : UnknownValue('unknown buffer size'),
            outcome.frame,
          ),
        );
      } else if ((name == 'isEmpty' || name == 'isNotEmpty') &&
          (value is ListValue || value is MapValue || value is TextValue)) {
        final empty = value is ListValue
            ? value.items.isEmpty
            : value is MapValue
            ? value.entries.isEmpty
            : (value as TextValue).text.text.isEmpty;
        result.add(_scalar(name == 'isEmpty' ? empty : !empty, outcome.frame));
      } else if (name == 'length' && value is TextValue) {
        result.add(_scalar(value.text.text.length, outcome.frame));
      } else {
        result.addAll(
          objects.property(value, name, outcome.frame, this) ??
              [_unknown(outcome.frame, 'unknown property')],
        );
      }
    }
    return _bounded(result, frame);
  }

  List<StaticOutcome> _method(MethodInvocation call, StaticFrame frame) {
    final name = call.methodName.name;
    final copyType = call.target is SimpleIdentifier
        ? (call.target as SimpleIdentifier).name
        : call.target == null
        ? name
        : null;
    final coreCopy = copyType == null
        ? null
        : _copyConstructor(
            copyType,
            call.target == null ? '' : name,
            call.argumentList,
            call,
            frame,
          );
    if (coreCopy != null) return coreCopy;
    if (name == 'StringBuffer' &&
        call.target == null &&
        _coreStringBuffer(call, frame)) {
      if (call.argumentList.arguments.isEmpty) {
        return [StaticOutcome(BufferValue(_empty(call, frame)), frame)];
      }
      if (call.argumentList.arguments.length == 1) {
        return [
          for (final value in evaluate(
            call.argumentList.arguments.single.argumentExpression,
            frame,
          ))
            StaticOutcome(
              _bufferValue(value.value, call, value.frame),
              value.frame,
            ),
        ];
      }
    }
    if (name == 'named' &&
        call.target != null &&
        _namedParameters('${call.target!.toSource()}.named')) {
      return _bindings(call.argumentList, frame);
    }
    final constructed = objects.evaluate(call, frame, this);
    if (constructed != null) return constructed;
    final declaration = frame.unit.sources.resolve(call, frame.unit);
    if (declaration != null &&
        (declaration.node is FunctionDeclaration ||
            declaration.node is MethodDeclaration &&
                ((declaration.node as MethodDeclaration).isStatic ||
                    frame.receiver?.exact == true))) {
      return invokeCallable(
        declaration,
        call.argumentList,
        frame,
        receiver:
            declaration.node is MethodDeclaration &&
                !(declaration.node as MethodDeclaration).isStatic
            ? frame.receiver
            : null,
      );
    }
    final target = call.isCascaded
        ? [
            StaticOutcome(
              frame.cascadeTarget ?? UnknownValue('unknown cascade'),
              frame,
            ),
          ]
        : call.target != null
        ? evaluate(call.target!, frame)
        : frame.receiver != null
        ? [StaticOutcome(frame.receiver!, frame)]
        : null;
    if (target != null) {
      final results = <StaticOutcome>[];
      for (final receiver in target) {
        if (receiver.value is _SkippedNullValue ||
            call.isNullAware &&
                receiver.value is ScalarValue &&
                (receiver.value as ScalarValue).value == null) {
          results.add(StaticOutcome(_SkippedNullValue(), receiver.frame));
          continue;
        }
        final builtin = _builtin(receiver.value, call, receiver.frame);
        if (builtin != null) {
          results.addAll(builtin);
          continue;
        }
        final delegated = objects.method(
          receiver.value,
          call,
          receiver.frame,
          this,
        );
        if (delegated != null) {
          results.addAll(delegated);
          continue;
        }
        _invalidate(receiver.value);
        results.addAll(
          _databaseCall(call)
              ? _databaseArguments(call.argumentList, receiver.frame)
              : _unknownCall(call.argumentList, receiver.frame),
        );
      }
      return _bounded(results, frame);
    }
    return objects.evaluate(call, frame, this) ??
        _unknownCall(call.argumentList, frame);
  }

  List<StaticOutcome> _bindings(ArgumentList arguments, StaticFrame frame) {
    if (arguments.arguments.length != 1) {
      return [_unknown(frame, 'invalid parameter wrapper')];
    }
    return [
      for (final value in evaluate(
        arguments.arguments.single.argumentExpression,
        frame,
      ))
        StaticOutcome(
          value.value is MapValue
              ? BindingsValue(value.value as MapValue)
              : UnknownValue('unknown parameter map'),
          value.frame,
        ),
    ];
  }

  bool _coreStringBuffer(AstNode use, StaticFrame frame) =>
      _coreType('StringBuffer', use, frame);

  bool _namedParameters(String name) =>
      name == 'QueryParameters.named' ||
      name.endsWith('.QueryParameters.named');

  List<StaticOutcome> _unknownCall(
    ArgumentList arguments,
    StaticFrame frame, {
    String reason = 'unknown call',
  }) {
    var states = [frame];
    for (final argument in arguments.arguments) {
      final next = <StaticFrame>[];
      for (final state in states) {
        for (final value in evaluate(argument.argumentExpression, state)) {
          _invalidate(value.value);
          next.add(value.frame);
        }
      }
      states = next.length > limit ? [_invalidateAll(frame)] : next;
    }
    return [for (final state in states) _unknown(state, reason)];
  }

  List<StaticOutcome> _databaseArguments(
    ArgumentList arguments,
    StaticFrame frame,
  ) {
    var states = [frame];
    for (final argument in arguments.arguments) {
      final next = <StaticFrame>[];
      for (final state in states) {
        for (final outcome in evaluate(argument.argumentExpression, state)) {
          final value = outcome.value;
          if (argument is NamedArgument &&
              argument.name.lexeme == 'parameters' &&
              value is BindingsValue) {
            for (final item in value.map.entries.values) {
              _invalidate(item);
            }
          } else {
            _invalidate(value);
          }
          next.add(outcome.frame);
        }
      }
      states = next.length > limit ? [_invalidateAll(frame)] : next;
    }
    return [
      for (final state in states) _unknown(state, 'runtime database result'),
    ];
  }

  List<StaticOutcome>? _builtin(
    StaticValue receiver,
    MethodInvocation call,
    StaticFrame frame,
  ) {
    final anchor = Object();
    frame.env[anchor] = receiver;
    final result = _builtinValue(receiver, call, frame, anchor);
    for (final outcome in result ?? <StaticOutcome>[]) {
      outcome.frame.env.remove(anchor);
    }
    frame.env.remove(anchor);
    return result;
  }

  List<StaticOutcome>? _builtinValue(
    StaticValue receiver,
    MethodInvocation call,
    StaticFrame frame,
    Object anchor,
  ) {
    final name = call.methodName.name;
    final arguments = call.argumentList.arguments;
    if ((receiver is ListValue || receiver is IterableValue) &&
        (name == 'firstWhere' || name == 'singleWhere')) {
      return _searchIterable(receiver, call, frame);
    }
    if (receiver is TextValue) {
      final transformed = _stringBuiltin(receiver, call, frame);
      if (transformed != null) return transformed;
    }
    if (receiver is IterableValue ||
        receiver is ListValue &&
            const {'map', 'where', 'toList'}.contains(name)) {
      return _iterableBuiltin(receiver, call, frame);
    }
    if (receiver is BufferValue) {
      if (name == 'toString' && arguments.isEmpty) {
        return [
          StaticOutcome(
            receiver.known
                ? TextValue(receiver.text)
                : UnknownValue('unknown buffer'),
            frame,
          ),
        ];
      }
      if (name == 'clear' && arguments.isEmpty) {
        receiver.text = _empty(call, frame);
        return [_scalar(null, frame)];
      }
      if (name == 'write' || name == 'writeln') {
        if (arguments.length > 1) return null;
        final inputs = arguments.isEmpty
            ? [_scalar('', frame)]
            : evaluate(arguments.single.argumentExpression, frame);
        return [
          for (final input in inputs)
            _bufferWrite(
              input.frame.env[anchor]! as BufferValue,
              input,
              call,
              newline: name == 'writeln',
            ),
        ];
      }
      if (name == 'writeAll' && arguments.isNotEmpty && arguments.length <= 2) {
        final values = <StaticOutcome>[];
        for (final list in evaluate(
          arguments.first.argumentExpression,
          frame,
        )) {
          for (final separator
              in arguments.length == 2
                  ? evaluate(arguments.last.argumentExpression, list.frame)
                  : [
                      StaticOutcome(
                        TextValue(_empty(call, list.frame)),
                        list.frame,
                      ),
                    ]) {
            final joined = _join(
              list.value,
              separator.value,
              call,
              separator.frame,
            );
            values.add(
              _bufferWrite(
                separator.frame.env[anchor]! as BufferValue,
                StaticOutcome(joined, separator.frame),
                call,
              ),
            );
          }
        }
        return values;
      }
      return null;
    }
    if (receiver is ListValue) {
      if (name == 'join' && arguments.length <= 1) {
        return [
          for (final separator
              in arguments.isEmpty
                  ? [StaticOutcome(TextValue(_empty(call, frame)), frame)]
                  : evaluate(arguments.single.argumentExpression, frame))
            StaticOutcome(
              receiver.known
                  ? _join(
                      separator.frame.env[anchor]!,
                      separator.value,
                      call,
                      separator.frame,
                    )
                  : UnknownValue('unknown list'),
              separator.frame,
            ),
        ];
      }
      if (name == 'clear' && arguments.isEmpty) {
        receiver.items.clear();
        return [_scalar(null, frame)];
      }
      if ((name == 'add' || name == 'addAll') && arguments.length == 1) {
        return [
          for (final item in evaluate(
            arguments.single.argumentExpression,
            frame,
          ))
            _listAdd(
              item.frame.env[anchor]! as ListValue,
              item,
              name == 'addAll',
            ),
        ];
      }
      if (name == 'removeAt' && arguments.length == 1) {
        return [
          for (final index in evaluate(
            arguments.single.argumentExpression,
            frame,
          ))
            _listRemoveAt(index.frame.env[anchor]! as ListValue, index),
        ];
      }
      if (name == 'toList' && arguments.isEmpty) {
        return [
          StaticOutcome(
            ListValue([...receiver.items])..known = receiver.known,
            frame,
          ),
        ];
      }
      return null;
    }
    if (receiver is MapValue) {
      if (name == 'map') return _mapEntries(receiver, call, frame);
      if (name == 'containsKey' && arguments.length == 1) {
        return _withArguments(call.argumentList, frame, (values, named, state) {
          final current = state.env[anchor];
          return current is MapValue &&
                  current.known &&
                  values.length == 1 &&
                  values.single is TextValue &&
                  named.isEmpty
              ? ScalarValue(
                  current.entries.containsKey(
                    (values.single as TextValue).text.text,
                  ),
                )
              : UnknownValue('unknown map key');
        });
      }
      if (name == 'clear' && arguments.isEmpty) {
        receiver.entries.clear();
        return [_scalar(null, frame)];
      }
      if (name == 'addAll' && arguments.length == 1) {
        return [
          for (final other in evaluate(
            arguments.single.argumentExpression,
            frame,
          ))
            _mapAdd(other.frame.env[anchor]! as MapValue, other),
        ];
      }
      if (name == 'remove' && arguments.length == 1) {
        final result = <StaticOutcome>[];
        for (final key in evaluate(
          arguments.single.argumentExpression,
          frame,
        )) {
          final map = key.frame.env[anchor]! as MapValue;
          if (!map.known) {
            result.add(_unknown(key.frame, 'unknown removed value'));
          } else if (key.value is TextValue) {
            result.add(
              StaticOutcome(
                map.entries.remove((key.value as TextValue).text.text) ??
                    ScalarValue(null),
                key.frame,
              ),
            );
          } else {
            (key.frame.env[anchor]! as MapValue).known = false;
            result.add(_unknown(key.frame, 'unknown removed key'));
          }
        }
        return result;
      }
      return null;
    }
    if (receiver is TextValue && name == 'toString' && arguments.isEmpty) {
      return [StaticOutcome(receiver, frame)];
    }
    if (receiver is ScalarValue && name == 'toString' && arguments.isEmpty) {
      return [StaticOutcome(_asText(receiver, call, frame), frame)];
    }
    return null;
  }

  List<StaticOutcome> _withArguments(
    ArgumentList arguments,
    StaticFrame frame,
    StaticValue Function(
      List<StaticValue>,
      Map<String, StaticValue>,
      StaticFrame,
    )
    apply,
  ) {
    final anchor = Object();
    frame.env[anchor] = RecordValue([], {});
    var states = [frame];
    for (final argument in arguments.arguments) {
      final next = <StaticFrame>[];
      for (final state in states) {
        for (final value in evaluate(argument.argumentExpression, state)) {
          final values = value.frame.env[anchor];
          if (values is! RecordValue) continue;
          final entry = _chainValue(value.value);
          if (argument is NamedArgument) {
            if (values.named.containsKey(argument.name.lexeme)) {
              next.add(_invalidateAll(value.frame));
              continue;
            }
            values.named[argument.name.lexeme] = entry;
          } else {
            values.positional.add(entry);
          }
          next.add(value.frame);
        }
      }
      if (next.length > limit) {
        for (final state in next) {
          state.env.remove(anchor);
        }
        frame.env.remove(anchor);
        return [_unknown(_invalidateAll(frame), 'argument expansion limit')];
      }
      states = next;
    }
    final result = <StaticOutcome>[];
    for (final state in states) {
      final values = state.env.remove(anchor);
      result.add(
        StaticOutcome(
          values is RecordValue
              ? apply(values.positional, values.named, state)
              : UnknownValue('unreadable arguments'),
          state,
        ),
      );
    }
    frame.env.remove(anchor);
    return result;
  }

  List<StaticOutcome>? _stringBuiltin(
    TextValue receiver,
    MethodInvocation call,
    StaticFrame frame,
  ) {
    final method = call.methodName.name;
    const methods = {
      'toLowerCase',
      'toUpperCase',
      'trim',
      'trimLeft',
      'trimRight',
      'replaceAll',
      'replaceFirst',
      'substring',
      'split',
      'contains',
      'startsWith',
      'endsWith',
    };
    if (!methods.contains(method)) return null;
    return _withArguments(call.argumentList, frame, (args, named, state) {
      if (named.isNotEmpty) return UnknownValue('unsupported string arguments');
      final source = receiver.text;
      final value = source.text;
      int? integer(int i) =>
          i < args.length &&
              args[i] is ScalarValue &&
              (args[i] as ScalarValue).value is int
          ? (args[i] as ScalarValue).value as int
          : null;
      String? string(int i) => i < args.length && args[i] is TextValue
          ? (args[i] as TextValue).text.text
          : null;
      if (const {
        'toLowerCase',
        'toUpperCase',
        'trim',
        'trimLeft',
        'trimRight',
      }.contains(method)) {
        if (args.isNotEmpty) {
          return UnknownValue('unsupported string arguments');
        }
        if (method == 'trim' || method == 'trimLeft' || method == 'trimRight') {
          final start = method == 'trimRight'
              ? 0
              : value.length - value.trimLeft().length;
          final end = method == 'trimLeft'
              ? value.length
              : value.trimRight().length;
          return TextValue(
            _sliceText(source, start, end < start ? start : end),
          );
        }
        final result = method == 'toLowerCase'
            ? value.toLowerCase()
            : value.toUpperCase();
        return TextValue(
          StaticText(
            result,
            result.length == value.length ? source.origins : null,
            source.endOrigin,
          ),
        );
      }
      if (method == 'substring') {
        final start = integer(0);
        final end = args.length == 1 ? value.length : integer(1);
        if (args.isEmpty ||
            args.length > 2 ||
            start == null ||
            end == null ||
            start < 0 ||
            end < start ||
            end > value.length) {
          return UnknownValue('invalid or runtime substring range');
        }
        return TextValue(_sliceText(source, start, end));
      }
      if (method == 'replaceAll' || method == 'replaceFirst') {
        final pattern = string(0);
        final replacement = args.length > 1 && args[1] is TextValue
            ? (args[1] as TextValue).text
            : null;
        final start = method == 'replaceAll' || args.length == 2
            ? 0
            : integer(2);
        if (args.length < 2 ||
            args.length > (method == 'replaceAll' ? 2 : 3) ||
            pattern == null ||
            replacement == null ||
            start == null ||
            start < 0 ||
            start > value.length) {
          return UnknownValue(
            'replacement requires readable literal strings and range',
          );
        }
        if (pattern.isEmpty) {
          final replaced = method == 'replaceAll'
              ? value.replaceAll(pattern, replacement.text)
              : value.replaceFirst(pattern, replacement.text, start);
          return TextValue(StaticText(replaced, null, source.endOrigin));
        }
        var result = _sliceText(source, 0, 0);
        var offset = 0;
        var search = start;
        while (true) {
          final match = value.indexOf(pattern, search);
          if (match < 0) break;
          result = result
              .append(_sliceText(source, offset, match))
              .append(replacement);
          offset = match + pattern.length;
          search = offset;
          if (method == 'replaceFirst') break;
        }
        return TextValue(
          result.append(_sliceText(source, offset, value.length)),
        );
      }
      if (method == 'split') {
        final separator = string(0);
        if (args.length != 1 || separator == null) {
          return UnknownValue('split requires a readable string delimiter');
        }
        final parts = value.split(separator);
        if (parts.length > limit) return UnknownValue('split exceeds 32 items');
        var offset = 0;
        final values = <StaticValue>[];
        for (final part in parts) {
          values.add(
            TextValue(_sliceText(source, offset, offset + part.length)),
          );
          offset += part.length + separator.length;
        }
        return ListValue(values);
      }
      final pattern = string(0);
      final start = args.length == 1 ? 0 : integer(1);
      if (pattern == null ||
          args.isEmpty ||
          args.length > (method == 'endsWith' ? 1 : 2) ||
          start == null ||
          start < 0 ||
          start > value.length) {
        return UnknownValue('string match requires readable arguments');
      }
      return ScalarValue(switch (method) {
        'contains' => value.contains(pattern, start),
        'startsWith' => value.startsWith(pattern, start),
        'endsWith' => value.endsWith(pattern),
        _ => false,
      });
    });
  }

  StaticText _sliceText(StaticText source, int start, int end) => StaticText(
    source.text.substring(start, end),
    source.origins?.sublist(start, end),
    end < source.text.length && source.origins != null
        ? source.origins![end]
        : source.endOrigin,
  );

  StaticValue _chainValue(StaticValue value) =>
      value is _SkippedNullValue ? ScalarValue(null) : value;

  bool _coreType(String name, AstNode use, StaticFrame frame) =>
      frame.unit.sources.coreTypeAvailable(name, use, frame.unit);

  List<StaticOutcome>? _finiteParameter(
    DartDeclaration declaration,
    StaticFrame frame,
  ) {
    final parameter = declaration.node as FormalParameter;
    final type = parameter.type;
    if (type is! NamedType || parameter.functionTypedSuffix != null) {
      return null;
    }
    final current = frame.env[parameter];
    if (current is UnknownValue && current.reason == 'captured mutation') {
      return null;
    }
    final target = declaration.unit.sources.resolveNamedType(
      type,
      parameter,
      declaration.unit,
    );
    final node = target?.node;
    if (node is! EnumDeclaration || !target!.unit.readable) return null;
    final constants = node.body.constants;
    final nullable = type.question != null;
    if (constants.isEmpty || constants.length + (nullable ? 1 : 0) > limit) {
      return null;
    }
    // Bind the finite domain at its first read. Later helper calls and binding
    // expressions see the same enum value on this path rather than expanding
    // unrelated copies of the formal parameter.
    final values = <StaticValue>[
      for (var i = 0; i < constants.length; i++)
        EnumValue(target, i, constants[i].name.lexeme),
      if (nullable) ScalarValue(null),
    ];
    return [
      for (final value in values)
        _bindFiniteParameter(frame.copy(), parameter, value),
    ];
  }

  StaticOutcome _bindFiniteParameter(
    StaticFrame frame,
    FormalParameter parameter,
    StaticValue value,
  ) {
    frame.env[parameter] = value;
    return StaticOutcome(value, frame);
  }

  List<StaticOutcome>? _copyConstructor(
    String type,
    String name,
    ArgumentList arguments,
    AstNode use,
    StaticFrame frame,
  ) {
    if (!const {'Map', 'List', 'MapEntry'}.contains(type) ||
        !_coreType(type, use, frame)) {
      return null;
    }
    if (type == 'MapEntry' && name.isEmpty) {
      return _withArguments(
        arguments,
        frame,
        (positional, named, _) => positional.length == 2 && named.isEmpty
            ? MapEntryValue(positional[0], positional[1])
            : UnknownValue('invalid MapEntry arguments'),
      );
    }
    if (!const {'from', 'of', 'unmodifiable'}.contains(name)) return null;
    if (type == 'Map') {
      return _withArguments(arguments, frame, (positional, named, _) {
        if (positional.length != 1 ||
            named.isNotEmpty ||
            positional.single is! MapValue) {
          return UnknownValue('map copy requires a readable map');
        }
        final source = positional.single as MapValue;
        return MapValue({...source.entries})..known = source.known;
      });
    }
    final result = <StaticOutcome>[];
    for (final value in _withArguments(arguments, frame, (
      positional,
      named,
      _,
    ) {
      if (positional.length != 1 ||
          named.keys.any((key) => key != 'growable') ||
          named.values.any(
            (value) => value is! ScalarValue || value.value is! bool,
          )) {
        return UnknownValue('list copy requires a readable iterable');
      }
      return positional.single;
    })) {
      for (final list in _materialize(value.value, value.frame)) {
        result.add(
          StaticOutcome(
            list.value is ListValue
                ? (ListValue([...(list.value as ListValue).items])
                    ..known = (list.value as ListValue).known)
                : list.value,
            list.frame,
          ),
        );
      }
    }
    return _bounded(result, frame);
  }

  List<StaticOutcome> _evaluateIterable(
    Expression expression,
    StaticFrame frame,
  ) => [
    for (final value in evaluate(expression, frame))
      ..._materialize(value.value, value.frame),
  ];

  StaticValue _collectionProperty(StaticValue value, String name) {
    if (value is! ListValue || !value.known) {
      return UnknownValue('unknown iterable property');
    }
    if (name == 'length') return ScalarValue(value.items.length);
    if (name == 'isEmpty') return ScalarValue(value.items.isEmpty);
    if (name == 'isNotEmpty') return ScalarValue(value.items.isNotEmpty);
    if (value.items.isEmpty || name == 'single' && value.items.length != 1) {
      return UnknownValue('invalid iterable property');
    }
    return name == 'last' ? value.items.last : value.items.first;
  }

  List<StaticOutcome> _iterableProperty(
    StaticValue source,
    String name,
    StaticFrame frame, {
    int depth = 0,
  }) {
    if (depth >= limit) {
      return [_unknown(frame, 'iterable property depth limit')];
    }
    if (source is ListValue) {
      return [StaticOutcome(_collectionProperty(source, name), frame)];
    }
    if (source is! IterableValue) {
      return [_unknown(frame, 'unknown iterable property')];
    }
    final count = const {'length', 'isEmpty', 'isNotEmpty'}.contains(name);
    if (source.kind == 'map' &&
        source.callback != null &&
        source.unit != null) {
      // Dart's mapped views delegate their size and indexed properties to the
      // source; checking length or emptiness never invokes the mapper.
      final selected = _iterableProperty(
        source.source,
        name,
        frame,
        depth: depth + 1,
      );
      if (count) return selected;
      return [
        for (final value in selected)
          if (value.value is UnknownValue)
            value
          else
            ..._callback(
              source.callback!,
              [value.value],
              source.unit!,
              value.frame,
            ),
      ];
    }
    if (source.source is MapValue &&
        const {'keys', 'values', 'entries'}.contains(source.kind) &&
        count) {
      final map = source.source as MapValue;
      return [
        map.known
            ? _scalar(
                name == 'length'
                    ? map.entries.length
                    : name == 'isEmpty'
                    ? map.entries.isEmpty
                    : map.entries.isNotEmpty,
                frame,
              )
            : _unknown(frame, 'unknown map view'),
      ];
    }
    final partial =
        const {'where', 'opaqueWhere'}.contains(source.kind) &&
        const {'isEmpty', 'isNotEmpty', 'first', 'single'}.contains(name);
    if (!partial) {
      return [
        for (final value in _materialize(source, frame))
          StaticOutcome(_collectionProperty(value.value, name), value.frame),
      ];
    }
    // A filtered first/empty/single lookup can stop before the final input.
    // A full traversal proves these properties only if callbacks leave the
    // source and caller state unchanged. Otherwise preserve uncertainty,
    // rather than applying effects from elements Dart would never consume.
    final anchor = Object();
    frame.env[anchor] = source;
    final snapshot = frame.copy();
    final values = _materialize(snapshot.env[anchor]!, snapshot);
    if (values.any(
      (value) => StaticFrame.joinEquivalent([frame, value.frame]) == null,
    )) {
      frame.env.remove(anchor);
      return [
        _unknown(_invalidateAll(frame), 'partial iterable callback effects'),
      ];
    }
    final result = [
      for (final value in values)
        StaticOutcome(_collectionProperty(value.value, name), value.frame),
    ];
    for (final value in result) {
      value.frame.env.remove(anchor);
    }
    frame.env.remove(anchor);
    return _bounded(result, frame);
  }

  List<StaticOutcome> _materialize(
    StaticValue source,
    StaticFrame frame, {
    int depth = 0,
  }) {
    if (depth >= limit) return [_unknown(frame, 'iterable depth limit')];
    if (source is ListValue) {
      return [
        StaticOutcome(
          source.known && source.items.length <= limit
              ? source
              : UnknownValue('unknown or unbounded iterable'),
          frame,
        ),
      ];
    }
    if (source is! IterableValue) return [_unknown(frame, 'runtime iterable')];
    final value = source.source;
    if (value is MapValue &&
        const {'keys', 'values', 'entries'}.contains(source.kind)) {
      if (!value.known || value.entries.length > limit) {
        return [_unknown(frame, 'unknown map view')];
      }
      return [
        StaticOutcome(
          ListValue([
            for (final entry in value.entries.entries)
              source.kind == 'keys'
                  ? TextValue(StaticText.synthetic(entry.key, frame.unit, 0))
                  : source.kind == 'values'
                  ? entry.value
                  : MapEntryValue(
                      TextValue(StaticText.synthetic(entry.key, frame.unit, 0)),
                      entry.value,
                    ),
          ]),
          frame,
        ),
      ];
    }
    final opaque = source.kind == 'opaqueWhere';
    if (!const {'map', 'where', 'opaqueWhere'}.contains(source.kind) ||
        (opaque ? source.predicate == null : source.callback == null) ||
        source.unit == null) {
      return [_unknown(frame, 'unreadable iterable view')];
    }
    if (opaque) {
      _invalidateOpaquePredicate(source.predicate!, source.unit!, frame);
    }
    final results = <StaticOutcome>[];
    final anchor = Object();
    for (final input in _materialize(value, frame, depth: depth + 1)) {
      if (input.value is! ListValue) {
        results.add(input);
        continue;
      }
      final list = input.value as ListValue;
      input.frame.env[anchor] = RecordValue([list, ListValue([])], {});
      var states = [input.frame];
      for (var i = 0; i < list.items.length; i++) {
        final next = <StaticFrame>[];
        for (final state in states) {
          final held = state.env[anchor] as RecordValue;
          final items = held.positional.first as ListValue;
          if (!items.known || i >= items.items.length) {
            next.add(_invalidateAll(state));
            continue;
          }
          final outcomes = opaque
              ? [_opaquePredicateInput(items.items[i], state)]
              : _callback(
                  source.callback!,
                  [items.items[i]],
                  source.unit!,
                  state,
                );
          for (final outcome in outcomes) {
            final current = outcome.frame.env[anchor] as RecordValue;
            final output = current.positional.last as ListValue;
            if (source.kind == 'map') {
              output.items.add(outcome.value);
              next.add(outcome.frame);
            } else if (outcome.value is ScalarValue &&
                (outcome.value as ScalarValue).value is bool) {
              if ((outcome.value as ScalarValue).value as bool) {
                output.items.add(
                  (current.positional.first as ListValue).items[i],
                );
              }
              next.add(outcome.frame);
            } else if (outcome.value is UnknownValue) {
              final yes = outcome.frame.copy();
              final selected = yes.env[anchor] as RecordValue;
              (selected.positional.last as ListValue).items.add(
                (selected.positional.first as ListValue).items[i],
              );
              next.add(yes);
              next.add(outcome.frame);
            } else {
              output.known = false;
              next.add(outcome.frame);
            }
          }
        }
        if (next.length > limit) {
          states = [_invalidateAll(input.frame)];
          (input.frame.env[anchor] as RecordValue).positional.last =
              UnknownValue('iterable expansion exceeds 32 paths');
          break;
        }
        states = next;
      }
      for (final state in states) {
        final held = state.env.remove(anchor);
        results.add(
          StaticOutcome(
            held is RecordValue
                ? held.positional.last
                : UnknownValue('unknown iterable'),
            state,
          ),
        );
      }
    }
    frame.env.remove(anchor);
    return _bounded(results, frame);
  }

  bool _readableCallback(
    FunctionExpression callback,
    DartUnit unit, {
    int arity = 1,
  }) {
    return _callbackReadable.putIfAbsent((
      callback,
      unit,
      arity,
    ), () => _checkReadableCallback(callback, unit, arity));
  }

  bool _checkReadableCallback(
    FunctionExpression callback,
    DartUnit unit,
    int arity,
  ) {
    if (callback.body.isAsynchronous ||
        callback.body.isGenerator ||
        callback.parameters?.parameters.length != arity) {
      return false;
    }
    if (callback.parameters!.parameters.any(
      (parameter) => parameter.isNamed || parameter.defaultClause != null,
    )) {
      return false;
    }
    final receiverReads = _CallbackReceiverReads(unit);
    callback.body.accept(receiverReads);
    if (receiverReads.found) return false;
    final parameters = callback.parameters!.parameters.toSet();
    for (final reference in _references(callback.body, unit)) {
      final declaration = reference.target;
      if (declaration == null || parameters.contains(declaration)) continue;
      if (declaration is FormalParameter) return false;
      if (declaration is VariableDeclaration) {
        if (callback.body.offset <= declaration.offset &&
            declaration.end <= callback.body.end) {
          continue;
        }
        final list = declaration.parent;
        final owner = list?.parent;
        if (list is! VariableDeclarationList ||
            !(list.isConst ||
                list.isFinal &&
                    (owner is TopLevelVariableDeclaration ||
                        owner is FieldDeclaration && owner.isStatic))) {
          return false;
        }
      }
    }
    return true;
  }

  List<StaticOutcome> _callback(
    FunctionExpression callback,
    List<StaticValue> args,
    DartUnit unit,
    StaticFrame caller,
  ) {
    if (!_readableCallback(callback, unit, arity: args.length) ||
        caller.active.contains(callback)) {
      for (final argument in args) {
        _invalidate(argument);
      }
      _invalidateStatement(callback.body, caller.withUnit(unit));
      return [_unknown(caller, 'unreadable or captured callback')];
    }
    final frame = caller.withUnit(unit, helper: true);
    frame.active.add(callback);
    final parameters = callback.parameters!.parameters;
    final backup = Object();
    final present = {
      for (final parameter in parameters)
        if (frame.env.containsKey(parameter)) parameter,
    };
    frame.env[backup] = RecordValue([
      for (final parameter in parameters)
        frame.env[parameter] ?? UnknownValue('absent callback parameter'),
    ], {});
    for (var i = 0; i < args.length; i++) {
      frame.env[parameters[i]] = args[i];
      frame.versions[parameters[i]] = (frame.versions[parameters[i]] ?? 0) + 1;
    }
    final body = callback.body;
    final capturedTargets = _captures(body, unit);
    for (final target in capturedTargets) {
      final value = frame.env[target];
      if (value != null) _invalidate(value);
    }
    frame.invalidated.addAll(capturedTargets);
    final List<StaticOutcome> result;
    if (body is ExpressionFunctionBody) {
      result = evaluate(body.expression, frame);
    } else if (body is BlockFunctionBody) {
      result = [
        for (final flow in _statement(body.block, [_Flow(frame)]))
          StaticOutcome(
            flow.kind == _FlowKind.returned
                ? flow.value ?? UnknownValue('empty callback return')
                : UnknownValue('unreadable callback flow'),
            flow.frame,
          ),
      ];
    } else {
      result = [_unknown(frame, 'unreadable callback body')];
    }
    frame.active.remove(callback);
    return [
      for (final value in result)
        _restoreCallback(value, backup, present, callback, caller),
    ];
  }

  StaticOutcome _restoreCallback(
    StaticOutcome outcome,
    Object backup,
    Set<FormalParameter> present,
    FunctionExpression callback,
    StaticFrame caller,
  ) {
    final frame = outcome.frame.withUnit(caller.unit, helper: caller.helper);
    frame.active.remove(callback);
    final held = frame.env.remove(backup);
    final parameters = callback.parameters!.parameters;
    for (var i = 0; i < parameters.length; i++) {
      if (!present.contains(parameters[i])) {
        frame.env.remove(parameters[i]);
      } else {
        frame.env[parameters[i]] = held is RecordValue
            ? held.positional[i]
            : UnknownValue('lost callback context');
      }
    }
    return StaticOutcome(_chainValue(outcome.value), frame);
  }

  List<StaticOutcome> _iterableBuiltin(
    StaticValue receiver,
    MethodInvocation call,
    StaticFrame frame,
  ) {
    final method = call.methodName.name;
    final arguments = call.argumentList.arguments;
    if (method == 'map' || method == 'where') {
      final callback = arguments.length == 1
          ? arguments.single.argumentExpression
          : null;
      if (method == 'where' &&
          callback != null &&
          _opaquePredicateShape(callback, frame)) {
        if (callback is! FunctionExpression ||
            !_readableCallback(callback, frame.unit)) {
          _invalidateOpaquePredicate(callback, frame.unit, frame);
          return [
            StaticOutcome(
              IterableValue(
                receiver,
                'opaqueWhere',
                predicate: callback,
                unit: frame.unit,
              ),
              frame,
            ),
          ];
        }
      }
      if (callback is! FunctionExpression ||
          method == 'where' && !_opaquePredicateShape(callback, frame) ||
          !_readableCallback(callback, frame.unit)) {
        _invalidate(receiver);
        if (callback != null) _invalidateStatement(callback, frame);
        return [_unknown(frame, 'unreadable or captured iterable callback')];
      }
      return [
        StaticOutcome(
          IterableValue(receiver, method, callback: callback, unit: frame.unit),
          frame,
        ),
      ];
    }
    final sourceAnchor = Object();
    frame.env[sourceAnchor] = receiver;
    final prepared = _withArguments(call.argumentList, frame, (
      positional,
      named,
      state,
    ) {
      if (method == 'join' && positional.length <= 1 && named.isEmpty) {
        return RecordValue([
          state.env[sourceAnchor]!,
          positional.isEmpty
              ? TextValue(_empty(call, state))
              : positional.single,
        ], {});
      }
      if (method == 'toList' &&
          positional.isEmpty &&
          named.keys.every((key) => key == 'growable')) {
        return RecordValue([state.env[sourceAnchor]!], {});
      }
      return UnknownValue('unsupported iterable method arguments');
    });
    final results = <StaticOutcome>[];
    for (final value in prepared) {
      if (value.value is! RecordValue) {
        results.add(value);
        continue;
      }
      final input = value.value as RecordValue;
      for (final materialized in _materialize(
        input.positional.first,
        value.frame,
      )) {
        final list = materialized.value;
        if (list is! ListValue) {
          results.add(materialized);
          continue;
        }
        results.add(
          StaticOutcome(
            method == 'toList'
                ? ListValue([...list.items])
                : _join(list, input.positional.last, call, materialized.frame),
            materialized.frame,
          ),
        );
      }
    }
    for (final value in results) {
      value.frame.env.remove(sourceAnchor);
    }
    frame.env.remove(sourceAnchor);
    return _bounded(results, frame);
  }

  bool _opaquePredicateShape(Expression expression, StaticFrame frame) {
    if (expression is ParenthesizedExpression) {
      return _opaquePredicateShape(expression.expression, frame);
    }
    if (expression is FunctionExpression) {
      final parameters = expression.parameters?.parameters;
      if (expression.body.isAsynchronous ||
          expression.body.isGenerator ||
          parameters == null ||
          parameters.length != 1 ||
          parameters.single.isNamed ||
          parameters.single.defaultClause != null) {
        return false;
      }
      final returns = _facts(expression.body).returns;
      if (expression.body case ExpressionFunctionBody(:final expression)) {
        return !_knownNonBoolean(expression);
      }
      return !returns.values.any(_knownNonBoolean);
    }
    if (expression is! SimpleIdentifier &&
        expression is! PrefixedIdentifier &&
        expression is! PropertyAccess &&
        expression is! MethodInvocation) {
      return false;
    }
    final declaration = frame.unit.sources
        .resolve(expression, frame.unit)
        ?.node;
    final known = declaration == null ? null : frame.env[declaration];
    if (known is ScalarValue ||
        known is TextValue ||
        known is EnumValue ||
        known is ListValue ||
        known is MapValue ||
        known is BufferValue ||
        known is RecordValue ||
        known is BindingsValue ||
        known is IterableValue) {
      return false;
    }
    final TypeAnnotation? type;
    if (declaration is FormalParameter) {
      if (declaration.functionTypedSuffix != null) return true;
      type = declaration.type;
    } else if (declaration is VariableDeclaration) {
      final list = declaration.parent;
      type = list is VariableDeclarationList ? list.type : null;
      if (_knownNonBoolean(declaration.initializer) ||
          declaration.initializer is BooleanLiteral) {
        return false;
      }
    } else if (declaration is FunctionDeclaration) {
      if (expression is! MethodInvocation) return true;
      type = declaration.returnType;
    } else if (declaration is MethodDeclaration) {
      if (expression is! MethodInvocation && !declaration.isGetter) return true;
      type = declaration.returnType;
    } else {
      type = null;
    }
    return type is! NamedType ||
        !const {
          'String',
          'bool',
          'int',
          'double',
          'num',
          'List',
          'Map',
          'Set',
          'Iterable',
          'Record',
        }.contains(type.name.lexeme);
  }

  bool _knownNonBoolean(Expression? expression) =>
      expression is StringLiteral ||
      expression is IntegerLiteral ||
      expression is DoubleLiteral ||
      expression is NullLiteral ||
      expression is ListLiteral ||
      expression is SetOrMapLiteral ||
      expression is RecordLiteral;

  void _invalidateOpaquePredicate(
    Expression expression,
    DartUnit unit,
    StaticFrame frame,
  ) {
    final writes = _facts(expression).writes;
    bool own(AstNode declaration) =>
        expression is FunctionExpression &&
        expression.offset <= declaration.offset &&
        declaration.end <= expression.end;
    for (final reference in _references(expression, unit)) {
      final declaration = reference.target;
      if (declaration == null || own(declaration)) continue;
      final value = frame.env[declaration];
      if (value != null) _invalidate(value);
    }
    for (final target in writes.targets) {
      final declaration = unit.sources.resolve(target, unit)?.node;
      if (declaration == null || own(declaration)) continue;
      final value = frame.env[declaration];
      if (value != null) _invalidate(value);
      frame.env[declaration] = UnknownValue('opaque predicate mutation');
      frame.invalidated.add(declaration);
      frame.versions[declaration] = (frame.versions[declaration] ?? 0) + 1;
    }
    final helpers = <AstNode>{};
    for (final helper in _helpers(expression, unit)) {
      final body = _helperBody(helper.node);
      if (body == null || !helpers.add(helper.node)) continue;
      if (helpers.length > limit) {
        _invalidateAll(frame);
        return;
      }
      _invalidateStatement(body, frame.withUnit(helper.unit), helpers: helpers);
    }
  }

  StaticOutcome _opaquePredicateInput(StaticValue value, StaticFrame frame) {
    // Opaque code can expose or mutate the item it receives. Immutable text
    // and enum values retain their domain; nested mutable aliases do not.
    _invalidate(value);
    return _unknown(frame, 'opaque finite predicate');
  }

  StaticOutcome _skipMapValue(Expression expression, StaticFrame frame) {
    final source = expression is ParenthesizedExpression
        ? expression.expression
        : expression;
    final declaration = source is SimpleIdentifier
        ? frame.unit.sources.resolve(source, frame.unit)?.node
        : null;
    final bound =
        declaration is FormalParameter ||
        declaration != null && frame.env.containsKey(declaration);
    final literal =
        source is SimpleStringLiteral ||
        source is IntegerLiteral ||
        source is DoubleLiteral ||
        source is BooleanLiteral ||
        source is NullLiteral;
    if (bound && declaration != null && frame.env.containsKey(declaration)) {
      // Bound values require no branching and must retain container aliases.
      // A later escape through this parameter map can still mutate the value.
      return StaticOutcome(frame.env[declaration]!, frame);
    }
    if (!bound && !literal) _invalidateStatement(expression, frame);
    return _unknown(frame, 'undemanded parameter value');
  }

  List<StaticOutcome> _mapAddKeys(MethodInvocation call, StaticFrame frame) {
    final arguments = call.argumentList.arguments;
    if (arguments.length != 1 || arguments.single is NamedArgument) {
      return _unknownCall(call.argumentList, frame);
    }
    final source = arguments.single.argumentExpression;
    if (source is! SetOrMapLiteral) return evaluate(call, frame);
    final anchor = Object();
    final results = <StaticOutcome>[];
    for (final target in evaluate(call.target!, frame)) {
      if (target.value is! MapValue) {
        results.addAll(_unknownCall(call.argumentList, target.frame));
        continue;
      }
      target.frame.env[anchor] = target.value;
      for (final value in _collection(
        source.elements,
        target.frame,
        true,
        keysOnly: true,
      )) {
        results.add(_mapAdd(value.frame.env[anchor]! as MapValue, value));
      }
    }
    for (final result in results) {
      result.frame.env.remove(anchor);
    }
    frame.env.remove(anchor);
    return _bounded(results, frame);
  }

  List<StaticOutcome> _searchIterable(
    StaticValue source,
    MethodInvocation call,
    StaticFrame frame,
  ) {
    final positional = call.argumentList.arguments
        .where((argument) => argument is! NamedArgument)
        .toList();
    final named = call.argumentList.arguments
        .whereType<NamedArgument>()
        .toList();
    if (positional.length != 1 ||
        named.length > 1 ||
        named.any((argument) => argument.name.lexeme != 'orElse')) {
      return [_unknown(frame, 'unsupported iterable search arguments')];
    }
    final predicate = positional.single.argumentExpression;
    final orElse = named.isEmpty ? null : named.single.argumentExpression;
    if (!_opaquePredicateShape(predicate, frame)) {
      return [_unknown(frame, 'unreadable iterable predicate')];
    }
    final readable =
        predicate is FunctionExpression &&
        _readableCallback(predicate, frame.unit);
    if (!readable) _invalidateOpaquePredicate(predicate, frame.unit, frame);
    final predicateUnit = frame.unit;
    final anchor = Object();
    frame.env[anchor] = source;
    final expanded = source is ListValue ? frame : frame.copy();
    final input = _materialize(expanded.env[anchor]!, expanded);
    // Materializing a lazy source can run more mappers than this search would
    // consume. Accept that expansion only when caller/source state is equal.
    if (source is IterableValue &&
        input.any(
          (value) => StaticFrame.joinEquivalent([frame, value.frame]) == null,
        )) {
      frame.env.remove(anchor);
      return [
        _unknown(_invalidateAll(frame), 'partial iterable search effects'),
      ];
    }
    final results = <StaticOutcome>[];
    for (final value in input) {
      if (value.value is! ListValue) {
        results.add(value);
        continue;
      }
      final items = value.value as ListValue;
      value.frame.env[anchor] = RecordValue([items, _NoSelectionValue()], {});
      var states = [value.frame];
      for (var i = 0; i < items.items.length; i++) {
        final next = <StaticFrame>[];
        for (final state in states) {
          final held = state.env[anchor] as RecordValue;
          final list = held.positional.first as ListValue;
          if (!list.known || i >= list.items.length) {
            results.add(
              _unknown(_invalidateAll(state), 'unknown searched list'),
            );
            continue;
          }
          final outcomes = readable
              ? _callback(predicate, [list.items[i]], predicateUnit, state)
              : [_opaquePredicateInput(list.items[i], state)];
          for (final outcome in outcomes) {
            final truth =
                outcome.value is ScalarValue &&
                    (outcome.value as ScalarValue).value is bool
                ? (outcome.value as ScalarValue).value as bool
                : null;
            if (truth == null && outcome.value is! UnknownValue) {
              results.add(
                _unknown(outcome.frame, 'non-boolean iterable predicate'),
              );
              continue;
            }
            if (truth != false) {
              final matched = truth == null
                  ? outcome.frame.copy()
                  : outcome.frame;
              final current = matched.env[anchor] as RecordValue;
              final selected = (current.positional.first as ListValue).items[i];
              if (call.methodName.name == 'firstWhere') {
                results.add(StaticOutcome(selected, matched));
              } else if (current.positional.last is _NoSelectionValue) {
                current.positional.last = selected;
                next.add(matched);
              }
              // A second singleWhere match throws; it cannot return a query.
            }
            if (truth != true) next.add(outcome.frame);
          }
        }
        if (next.length > limit + 1 || results.length > limit) {
          results.add(
            _unknown(_invalidateAll(value.frame), 'iterable search limit'),
          );
          states = [];
          break;
        }
        states = next;
      }
      for (final state in states) {
        final selected = (state.env[anchor] as RecordValue).positional.last;
        if (selected is! _NoSelectionValue) {
          results.add(StaticOutcome(selected, state));
        } else if (orElse == null || _throwingCallback(orElse)) {
          // Default not-found errors and explicit throwing orElse callbacks
          // are terminal paths. A caller catch is handled conservatively by
          // statement flow, so these paths cannot silently supply SQL text.
          continue;
        } else if (orElse is FunctionExpression) {
          results.addAll(_callback(orElse, [], predicateUnit, state));
        } else {
          _invalidateOpaquePredicate(orElse, predicateUnit, state);
          results.add(_unknown(state, 'unreadable iterable fallback'));
        }
      }
    }
    for (final result in results) {
      result.frame.env.remove(anchor);
    }
    frame.env.remove(anchor);
    return _bounded(results, frame);
  }

  bool _throwingCallback(Expression expression) {
    if (expression is ParenthesizedExpression) {
      return _throwingCallback(expression.expression);
    }
    if (expression is! FunctionExpression ||
        expression.body.isAsynchronous ||
        expression.body.isGenerator ||
        expression.parameters?.parameters.isNotEmpty != false) {
      return false;
    }
    return expression.body is ExpressionFunctionBody &&
        (expression.body as ExpressionFunctionBody).expression
            is ThrowExpression;
  }

  List<StaticOutcome> _mapEntries(
    MapValue source,
    MethodInvocation call,
    StaticFrame frame,
  ) {
    final arguments = call.argumentList.arguments;
    final callback = arguments.length == 1
        ? arguments.single.argumentExpression
        : null;
    if (!source.known || source.entries.length > limit) {
      return [_unknown(frame, 'unknown or unbounded map')];
    }
    if (callback is! FunctionExpression ||
        !_readableCallback(callback, frame.unit, arity: 2)) {
      return [_unknown(frame, 'unreadable or captured map callback')];
    }
    final anchor = Object();
    final keys = source.entries.keys.toList();
    frame.env[anchor] = RecordValue([source, MapValue({})], {});
    var states = [frame];
    for (final key in keys) {
      final next = <StaticFrame>[];
      for (final state in states) {
        final held = state.env[anchor] as RecordValue;
        final input = held.positional.first;
        if (input is! MapValue ||
            !input.known ||
            !input.entries.containsKey(key)) {
          held.positional.last = UnknownValue('map changed during projection');
          next.add(state);
          continue;
        }
        for (final outcome in _callback(
          callback,
          [TextValue(_synthetic(key, call, state)), input.entries[key]!],
          frame.unit,
          state,
        )) {
          final current = outcome.frame.env[anchor] as RecordValue;
          final output = current.positional.last;
          final entry = outcome.value;
          if (output is MapValue &&
              entry is MapEntryValue &&
              entry.key is TextValue) {
            output.entries[(entry.key as TextValue).text.text] = entry.value;
          } else {
            current.positional.last = entry is UnknownValue
                ? entry
                : UnknownValue('map callback requires readable MapEntry keys');
          }
          next.add(outcome.frame);
        }
      }
      if (next.length > limit) {
        states = [_invalidateAll(frame)];
        (frame.env[anchor] as RecordValue).positional.last = UnknownValue(
          'map projection exceeds 32 paths',
        );
        break;
      }
      states = next;
    }
    final results = [
      for (final state in states)
        StaticOutcome(
          (state.env.remove(anchor) as RecordValue).positional.last,
          state,
        ),
    ];
    frame.env.remove(anchor);
    return _bounded(results, frame);
  }

  StaticOutcome _bufferWrite(
    BufferValue buffer,
    StaticOutcome input,
    AstNode node, {
    bool newline = false,
  }) {
    final value = _asText(input.value, node, input.frame);
    if (value is! TextValue) buffer.known = false;
    if (buffer.known && value is TextValue) {
      buffer.text = buffer.text.append(value.text);
      if (newline) {
        buffer.text = buffer.text.append(_synthetic('\n', node, input.frame));
      }
    }
    return _scalar(null, input.frame);
  }

  StaticOutcome _listAdd(ListValue list, StaticOutcome item, bool all) {
    if (all) {
      if (item.value is ListValue && (item.value as ListValue).known) {
        list.items.addAll((item.value as ListValue).items);
      } else {
        list.known = false;
      }
    } else {
      list.items.add(item.value);
    }
    if (list.items.length > limit) list.known = false;
    return _scalar(null, item.frame);
  }

  StaticOutcome _listRemoveAt(ListValue list, StaticOutcome index) {
    final value = index.value;
    if (list.known &&
        value is ScalarValue &&
        value.value is int &&
        (value.value as int) >= 0 &&
        (value.value as int) < list.items.length) {
      return StaticOutcome(
        list.items.removeAt(value.value as int),
        index.frame,
      );
    }
    list.known = false;
    return _unknown(index.frame, 'unknown removed index');
  }

  StaticOutcome _mapAdd(MapValue map, StaticOutcome other) {
    if (other.value is MapValue && (other.value as MapValue).known) {
      map.entries.addAll((other.value as MapValue).entries);
    } else {
      map.known = false;
    }
    return _scalar(null, other.frame);
  }

  StaticValue _join(
    StaticValue list,
    StaticValue separator,
    AstNode node,
    StaticFrame frame,
  ) {
    if (list is! ListValue || !list.known || list.items.length > limit) {
      return UnknownValue('unknown joined list');
    }
    final sep = _asText(separator, node, frame);
    if (sep is! TextValue) return UnknownValue('unknown separator');
    var joined = _empty(node, frame);
    for (var i = 0; i < list.items.length; i++) {
      final part = _asText(list.items[i], node, frame);
      if (part is! TextValue) return UnknownValue('unknown list item');
      if (i > 0) joined = joined.append(sep.text);
      joined = joined.append(part.text);
    }
    return TextValue(joined);
  }

  List<StaticOutcome> _collection(
    List<CollectionElement> elements,
    StaticFrame frame,
    bool map, {
    bool keysOnly = false,
  }) {
    var results = [StaticOutcome(map ? MapValue({}) : ListValue([]), frame)];
    for (final element in elements) {
      final next = <StaticOutcome>[];
      for (final result in results) {
        next.addAll(
          _collectionElement(
            element,
            result.value,
            result.frame,
            keysOnly: keysOnly,
          ),
        );
      }
      results = _bounded(next, frame);
    }
    return results;
  }

  List<StaticOutcome> _collectionElement(
    CollectionElement element,
    StaticValue container,
    StaticFrame frame, {
    bool keysOnly = false,
  }) {
    final anchor = Object();
    frame.env[anchor] = container;
    final result = _collectionElementValue(
      element,
      container,
      frame,
      anchor,
      keysOnly: keysOnly,
    );
    for (final outcome in result) {
      outcome.frame.env.remove(anchor);
    }
    frame.env.remove(anchor);
    return result;
  }

  List<StaticOutcome> _collectionElementValue(
    CollectionElement element,
    StaticValue container,
    StaticFrame frame,
    Object anchor, {
    bool keysOnly = false,
  }) {
    if (element is IfElement) {
      if (element.caseClause != null) {
        return [_unknown(frame, 'collection pattern')];
      }
      final result = <StaticOutcome>[];
      for (final branch in _branches(element.expression, frame)) {
        final selected = branch.truth
            ? element.thenElement
            : element.elseElement;
        final cloned = branch.frame.clonedValue(container);
        result.addAll(
          selected == null
              ? [StaticOutcome(cloned, branch.frame)]
              : _collectionElement(
                  selected,
                  cloned,
                  branch.frame,
                  keysOnly: keysOnly,
                ),
        );
      }
      return _bounded(result, frame);
    }
    if (element is SpreadElement) {
      final result = <StaticOutcome>[];
      for (final spread in evaluate(element.expression, frame)) {
        if (element.isNullAware &&
            spread.value is ScalarValue &&
            (spread.value as ScalarValue).value == null) {
          result.add(StaticOutcome(spread.frame.env[anchor]!, spread.frame));
        } else if (container is ListValue &&
            spread.value is ListValue &&
            (spread.value as ListValue).known) {
          (spread.frame.env[anchor]! as ListValue).items.addAll(
            (spread.value as ListValue).items,
          );
          result.add(StaticOutcome(spread.frame.env[anchor]!, spread.frame));
        } else if (container is MapValue &&
            spread.value is MapValue &&
            (spread.value as MapValue).known) {
          (spread.frame.env[anchor]! as MapValue).entries.addAll(
            (spread.value as MapValue).entries,
          );
          result.add(StaticOutcome(spread.frame.env[anchor]!, spread.frame));
        } else {
          result.add(_unknown(spread.frame, 'unknown spread'));
        }
      }
      return result;
    }
    if (element is ForElement) {
      final parts = element.forLoopParts;
      if (parts is! ForEachParts) {
        return [_unknown(frame, 'unknown collection loop')];
      }
      final result = <StaticOutcome>[];
      for (final iterable in _evaluateIterable(parts.iterable, frame)) {
        final list = iterable.value;
        if (list is! ListValue || !list.known || list.items.length > limit) {
          result.add(_unknown(iterable.frame, 'unknown collection iterable'));
          continue;
        }
        var values = [StaticOutcome(container, iterable.frame)];
        for (final item in list.items) {
          final next = <StaticOutcome>[];
          for (final value in values) {
            if (!_bindLoop(parts, item, value.frame)) {
              next.add(_unknown(value.frame, 'unknown loop variable'));
            } else {
              next.addAll(
                _collectionElement(
                  element.body,
                  value.value,
                  value.frame,
                  keysOnly: keysOnly,
                ),
              );
            }
          }
          values = _bounded(next, frame);
        }
        result.addAll(values);
      }
      return _bounded(result, frame);
    }
    if (element is MapLiteralEntry && container is MapValue) {
      final result = <StaticOutcome>[];
      for (final key in evaluate(element.key, frame)) {
        final values = keysOnly
            ? [_skipMapValue(element.value, key.frame)]
            : evaluate(element.value, key.frame);
        for (final value in values) {
          if (key.value is! TextValue) {
            result.add(_unknown(value.frame, 'unknown map key'));
          } else {
            (value.frame.env[anchor]! as MapValue)
                    .entries[(key.value as TextValue).text.text] =
                value.value;
            result.add(StaticOutcome(value.frame.env[anchor]!, value.frame));
          }
        }
      }
      return _bounded(result, frame);
    }
    if (element is Expression && container is ListValue) {
      return [
        for (final item in evaluate(element, frame))
          StaticOutcome(
            ListValue([
              ...(item.frame.env[anchor]! as ListValue).items,
              item.value,
            ])..known = (item.frame.env[anchor]! as ListValue).known,
            item.frame,
          ),
      ];
    }
    return [_unknown(frame, 'unknown collection element')];
  }

  List<StaticOutcome> _assign(
    AssignmentExpression expression,
    StaticFrame frame, {
    bool keysOnly = false,
  }) {
    final left = expression.leftHandSide;
    final declaration = frame.unit.sources.resolve(left, frame.unit)?.node;
    if (left is IndexExpression && left.target != null) {
      final anchor = Object();
      final result = <StaticOutcome>[];
      for (final target in evaluate(left.target!, frame)) {
        target.frame.env[anchor] = target.value;
        for (final index in evaluate(left.index, target.frame)) {
          final values =
              keysOnly &&
                  expression.operator.lexeme == '=' &&
                  target.value is MapValue
              ? [_skipMapValue(expression.rightHandSide, index.frame)]
              : evaluate(expression.rightHandSide, index.frame);
          for (final value in values) {
            if (expression.operator.lexeme != '=') {
              _invalidate(value.frame.env[anchor]!);
              result.add(_unknown(value.frame, 'compound index assignment'));
            } else if (target.value is MapValue && index.value is TextValue) {
              (value.frame.env[anchor]! as MapValue)
                      .entries[(index.value as TextValue).text.text] =
                  value.value;
              result.add(value);
            } else if (target.value is ListValue &&
                index.value is ScalarValue &&
                (index.value as ScalarValue).value is int) {
              final list = value.frame.env[anchor]! as ListValue;
              final at = (index.value as ScalarValue).value as int;
              if (at < 0 || at >= list.items.length) {
                list.known = false;
                result.add(_unknown(value.frame, 'invalid index'));
              } else {
                list.items[at] = value.value;
                result.add(value);
              }
            } else {
              _invalidate(value.frame.env[anchor]!);
              result.add(_unknown(value.frame, 'unknown assigned index'));
            }
          }
        }
      }
      for (final value in result) {
        value.frame.env.remove(anchor);
      }
      frame.env.remove(anchor);
      return _bounded(result, frame);
    }
    if (left is PropertyAccess || left is PrefixedIdentifier) {
      final Expression? receiver = left is PropertyAccess
          ? left.target
          : (left as PrefixedIdentifier).prefix;
      final result = <StaticOutcome>[];
      if (receiver != null) {
        for (final target in evaluate(receiver, frame)) {
          _invalidate(target.value);
          result.add(_unknown(target.frame, 'unknown object write'));
        }
        return result;
      }
      if (left is PropertyAccess &&
          left.isCascaded &&
          frame.cascadeTarget != null) {
        _invalidate(frame.cascadeTarget!);
      }
    }
    if (declaration is VariableDeclaration &&
        (declaration.parent?.parent is TopLevelVariableDeclaration ||
            declaration.parent?.parent is FieldDeclaration)) {
      final values = evaluate(expression.rightHandSide, frame);
      for (final value in values) {
        _invalidate(value.value);
      }
      return [
        for (final value in values) _unknown(value.frame, 'non-local write'),
      ];
    }
    if (declaration == null ||
        (declaration is! VariableDeclaration &&
            declaration is! FormalParameter &&
            declaration is! DeclaredIdentifier)) {
      return [_unknown(frame, 'unknown assigned target')];
    }
    final result = <StaticOutcome>[];
    for (final value in evaluate(expression.rightHandSide, frame)) {
      final old =
          value.frame.env[declaration] ?? UnknownValue('uninitialized value');
      final next = expression.operator.lexeme == '='
          ? _chainValue(value.value)
          : _binary(
              expression.operator.lexeme.replaceAll('=', ''),
              old,
              value.value,
              expression,
              value.frame,
            );
      value.frame.env[declaration] = next;
      value.frame.versions[declaration] =
          (value.frame.versions[declaration] ?? 0) + 1;
      result.add(StaticOutcome(next, value.frame));
    }
    return _bounded(result, frame);
  }

  List<StaticOutcome> _increment(
    Expression operand,
    String operator,
    StaticFrame frame,
    bool postfix,
  ) {
    final declaration = frame.unit.sources.resolve(operand, frame.unit)?.node;
    if (declaration == null) return [_unknown(frame, 'unknown increment')];
    final old = frame.env[declaration];
    if (old is ScalarValue && old.value is num) {
      final next = ScalarValue(
        (old.value as num) + (operator == '++' ? 1 : -1),
      );
      frame.env[declaration] = next;
      frame.versions[declaration] = (frame.versions[declaration] ?? 0) + 1;
      return [StaticOutcome(postfix ? old : next, frame)];
    }
    frame.env[declaration] = UnknownValue('unknown increment');
    frame.versions[declaration] = (frame.versions[declaration] ?? 0) + 1;
    return [_unknown(frame, 'unknown increment')];
  }

  @override
  List<StaticOutcome> invokeCallable(
    DartDeclaration target,
    ArgumentList arguments,
    StaticFrame caller, {
    ObjectValue? receiver,
  }) {
    final node = target.node;
    final FunctionBody body;
    final FormalParameterList? parameters;
    if (node is FunctionDeclaration && !node.isSetter) {
      body = node.functionExpression.body;
      parameters = node.functionExpression.parameters;
    } else if (node is MethodDeclaration && !node.isSetter) {
      body = node.body;
      parameters = node.parameters;
    } else if (node is ConstructorDeclaration && node.factoryKeyword != null) {
      body = node.body;
      parameters = node.parameters;
    } else {
      if (receiver != null) _invalidate(receiver);
      return _unknownCall(arguments, caller, reason: 'not a readable helper');
    }
    if (body.isAsynchronous ||
        body.isGenerator ||
        caller.active.contains(node) ||
        caller.active.length >= limit) {
      if (receiver != null) _invalidate(receiver);
      _invalidateStatement(body, caller.withUnit(target.unit));
      return _unknownCall(
        arguments,
        caller,
        reason: 'recursive or asynchronous helper',
      );
    }
    final positional = <Expression>[];
    final named = <String, Expression>{};
    for (final argument in arguments.arguments) {
      if (argument is NamedArgument) {
        if (named.containsKey(argument.name.lexeme)) {
          return [_unknown(caller, 'duplicate named argument')];
        }
        named[argument.name.lexeme] = argument.argumentExpression;
      } else {
        positional.add(argument.argumentExpression);
      }
    }
    final savedReceiver = caller.receiver;
    final receiverAnchor = Object();
    final bindings = {
      ..._facts(body).bindings.nodes,
      ...parameters?.parameters ?? <FormalParameter>[],
      if (receiver != null) ..._fields(receiver.type.node),
    };
    final owned = bindings.toList();
    final present = {
      for (final key in owned)
        if (caller.env.containsKey(key)) key,
    };
    final oldVersions = {
      for (final key in owned)
        if (caller.versions.containsKey(key)) key: caller.versions[key]!,
    };
    final oldInvalidated = caller.invalidated.intersection(bindings);
    final oldConditions = caller.conditions.keys.toSet();
    var frames = [caller.withUnit(target.unit, helper: true)];
    for (final frame in frames) {
      // A live receiver is part of the snapshot, not an external value to
      // reconstruct after nested helpers have copied their environments.
      frame.env[receiverAnchor] = RecordValue([
        savedReceiver ?? UnknownValue('no caller receiver'),
        for (final key in owned)
          frame.env[key] ?? UnknownValue('absent caller binding'),
      ], {});
      frame.receiver = receiver;
      if (receiver != null) {
        for (final declaration in _fields(receiver.type.node)) {
          frame.env[declaration] =
              receiver.fields[declaration.name.lexeme] ??
              UnknownValue('unknown field');
        }
      }
    }
    var position = 0;
    for (final parameter in parameters?.parameters ?? <FormalParameter>[]) {
      final supplied = parameter.isNamed
          ? named.remove(parameter.name?.lexeme)
          : position < positional.length
          ? positional[position++]
          : null;
      if (supplied == null && parameter.isRequired) {
        return [_unknown(caller, 'missing helper argument')];
      }
      final next = <StaticFrame>[];
      for (final frame in frames) {
        final valueExpression = supplied ?? parameter.defaultClause?.value;
        if (valueExpression == null) {
          frame.env[parameter] = ScalarValue(null);
          next.add(frame);
          continue;
        }
        final source = supplied == null ? target.unit : caller.unit;
        final values = evaluate(valueExpression, frame.withUnit(source));
        for (final value in values) {
          final restored = value.frame.withUnit(target.unit, helper: true);
          restored.env[parameter] = value.value;
          next.add(restored);
        }
      }
      if (next.length > limit) {
        if (receiver != null) _invalidate(receiver);
        return [_unknown(_invalidateAll(caller), 'helper argument limit')];
      }
      frames = next;
    }
    if (position != positional.length || named.isNotEmpty) {
      return [_unknown(caller, 'extra helper argument')];
    }
    final result = <StaticOutcome>[];
    for (final frame in frames) {
      frame.active.add(node);
      final targets = _captures(body, target.unit);
      for (final target in targets) {
        final value = frame.env[target];
        if (value != null) _invalidate(value);
      }
      frame.invalidated.addAll(targets);
      if (body is ExpressionFunctionBody) {
        result.addAll(evaluate(body.expression, frame));
      } else if (body is BlockFunctionBody) {
        final flow = _statement(body.block, [_Flow(frame)]);
        for (final outcome in flow) {
          result.add(
            StaticOutcome(
              outcome.kind == _FlowKind.returned
                  ? outcome.value ?? UnknownValue('empty return')
                  : UnknownValue('helper does not return'),
              outcome.frame,
            ),
          );
        }
      } else {
        result.add(_unknown(frame, 'unknown helper body'));
      }
    }
    caller.active.remove(node);
    final restored = <StaticOutcome>[];
    for (final value in result) {
      final context = value.frame.withUnit(caller.unit, helper: caller.helper);
      final previous = context.env.remove(receiverAnchor);
      context.receiver =
          previous is RecordValue && previous.positional.first is ObjectValue
          ? previous.positional.first as ObjectValue
          : null;
      for (var i = 0; i < owned.length; i++) {
        final key = owned[i];
        if (present.contains(key)) {
          context.env[key] = previous is RecordValue
              ? previous.positional[i + 1]
              : UnknownValue('lost caller binding');
        } else {
          context.env.remove(key);
        }
        if (oldVersions.containsKey(key)) {
          context.versions[key] = oldVersions[key]!;
        } else {
          context.versions.remove(key);
        }
        if (oldInvalidated.contains(key)) {
          context.invalidated.add(key);
        } else {
          context.invalidated.remove(key);
        }
      }
      context.conditions.removeWhere(
        (key, _) =>
            !oldConditions.contains(key) &&
            owned.any(
              (node) => key.contains('${target.unit.path}:${node.offset}:'),
            ),
      );
      context.active.remove(node);
      restored.add(StaticOutcome(_chainValue(value.value), context));
    }
    return _bounded(_collapsePrimitiveReturns(restored), caller);
  }

  List<StaticOutcome> _collapsePrimitiveReturns(List<StaticOutcome> values) {
    final result = <StaticOutcome>[];
    for (final value in values) {
      final primitive =
          value.value is ScalarValue ||
          value.value is TextValue ||
          value.value is EnumValue ||
          value.value is UnknownValue;
      var merged = false;
      if (primitive) {
        for (var i = 0; i < result.length; i++) {
          final prior = result[i];
          if (!equivalentStaticValues(prior.value, value.value)) continue;
          final frame = StaticFrame.joinEquivalent([prior.frame, value.frame]);
          if (frame == null) continue;
          result[i] = StaticOutcome(prior.value, frame);
          merged = true;
          break;
        }
      }
      if (!merged) result.add(value);
    }
    return result;
  }

  Iterable<VariableDeclaration> _fields(AstNode type) sync* {
    final members = type is ClassDeclaration
        ? type.body.members
        : type is EnumDeclaration
        ? type.body.members
        : <ClassMember>[];
    for (final field in members.whereType<FieldDeclaration>()) {
      if (!field.isStatic) yield* field.fields.variables;
    }
  }

  List<_Flow> _statement(
    Statement statement,
    List<_Flow> input, {
    AstNode? stop,
    Set<AstNode>? needed,
    Set<AstNode>? keysOnly,
    int depth = 0,
  }) {
    if (depth >= limit || input.length > limit) {
      return [
        for (final value in input)
          _Flow(_invalidateAll(value.frame), kind: _FlowKind.failed),
      ];
    }
    final untouched = input
        .where((value) => value.kind != _FlowKind.normal)
        .toList();
    final active = input
        .where((value) => value.kind == _FlowKind.normal)
        .toList();
    if (active.isEmpty) return input;
    final contains =
        stop != null &&
        statement.offset <= stop.offset &&
        stop.offset < statement.end;
    if (statement is Block) {
      var flow = input;
      for (final child in statement.statements) {
        if (stop != null && child.offset > stop.offset) break;
        flow = _statement(
          child,
          flow,
          stop: stop,
          depth: depth + 1,
          needed: needed,
          keysOnly: keysOnly,
        );
      }
      return flow;
    }
    if (statement is IfStatement) {
      final result = [...untouched];
      for (final value in active) {
        if (statement.caseClause != null) {
          result.add(
            _Flow(_invalidateAll(value.frame), kind: _FlowKind.failed),
          );
          continue;
        }
        for (final branch in _branches(statement.expression, value.frame)) {
          final selected = branch.truth
              ? statement.thenStatement
              : statement.elseStatement;
          if (stop != null &&
              contains &&
              (selected == null ||
                  !(selected.offset <= stop.offset &&
                      stop.offset < selected.end))) {
            continue;
          }
          result.addAll(
            selected == null
                ? [_Flow(branch.frame)]
                : _statement(
                    selected,
                    [_Flow(branch.frame)],
                    stop: stop,
                    depth: depth + 1,
                    needed: needed,
                    keysOnly: keysOnly,
                  ),
          );
        }
      }
      return _boundedFlow(result);
    }
    if (statement is ForStatement) {
      return [
        ...untouched,
        ..._for(
          statement,
          active,
          stop: stop,
          depth: depth + 1,
          needed: needed,
          keysOnly: keysOnly,
        ),
      ];
    }
    if (statement is SwitchStatement) {
      return [
        ...untouched,
        ..._switchStatement(
          statement,
          active,
          stop: stop,
          depth: depth + 1,
          needed: needed,
          keysOnly: keysOnly,
        ),
      ];
    }
    if (contains &&
        statement is TryStatement &&
        _contains(statement.body, stop)) {
      return [
        ...untouched,
        ..._statement(
          statement.body,
          active,
          stop: stop,
          depth: depth + 1,
          needed: needed,
          keysOnly: keysOnly,
        ),
      ];
    }
    if (contains) {
      if (statement is! ExpressionStatement &&
          statement is! VariableDeclarationStatement &&
          statement is! ReturnStatement) {
        for (final value in active) {
          _invalidateStatement(statement, value.frame);
        }
      }
      return [
        ...untouched,
        for (final value in active) _Flow(value.frame, kind: _FlowKind.reached),
      ];
    }
    if (statement is VariableDeclarationStatement) {
      var values = active;
      if (statement.variables.isLate) {
        for (final value in values) {
          for (final variable in statement.variables.variables) {
            value.frame.env[variable] = UnknownValue('late local');
          }
        }
      } else {
        for (final variable in statement.variables.variables) {
          final next = <_Flow>[];
          for (final value in values) {
            if (needed != null && !needed.contains(variable)) {
              if (variable.initializer case final initializer?) {
                _invalidateStatement(initializer, value.frame);
              }
              value.frame.env[variable] = UnknownValue(
                'undemanded local value',
              );
              next.add(_Flow(value.frame));
              continue;
            }
            final initializer = variable.initializer;
            final outcomes = initializer == null
                ? [_scalar(null, value.frame)]
                : keysOnly?.contains(variable) == true &&
                      initializer is SetOrMapLiteral
                ? _collection(
                    initializer.elements,
                    value.frame,
                    true,
                    keysOnly: true,
                  )
                : evaluate(initializer, value.frame);
            for (final outcome in outcomes) {
              outcome.frame.env[variable] = _chainValue(outcome.value);
              if (outcome.frame.invalidated.contains(variable)) {
                _invalidate(outcome.value);
              }
              next.add(_Flow(outcome.frame));
            }
          }
          values = _boundedFlow(next);
        }
      }
      return [...untouched, ...values];
    }
    if (statement is ReturnStatement) {
      return [
        ...untouched,
        for (final value in active)
          if (statement.expression == null)
            _Flow(
              value.frame,
              kind: _FlowKind.returned,
              value: ScalarValue(null),
            )
          else
            for (final outcome in evaluate(statement.expression!, value.frame))
              _Flow(
                outcome.frame,
                kind: _FlowKind.returned,
                value: outcome.value,
              ),
      ];
    }
    if (statement is BreakStatement) {
      return [
        ...untouched,
        for (final value in active) _Flow(value.frame, kind: _FlowKind.broken),
      ];
    }
    if (statement is ContinueStatement) {
      return [
        ...untouched,
        for (final value in active)
          _Flow(
            value.frame,
            kind: statement.label == null
                ? _FlowKind.continued
                : _FlowKind.failed,
          ),
      ];
    }
    if (statement is EmptyStatement ||
        statement is FunctionDeclarationStatement) {
      return input;
    }
    if (statement is ExpressionStatement) {
      final result = [...untouched];
      for (final value in active) {
        final expression = statement.expression;
        final left = expression is AssignmentExpression
            ? expression.leftHandSide
            : null;
        final target = left is IndexExpression && left.target != null
            ? value.frame.unit.sources
                  .resolve(left.target!, value.frame.unit)
                  ?.node
            : null;
        final outcomes =
            expression is AssignmentExpression &&
                target != null &&
                keysOnly?.contains(target) == true
            ? _assign(expression, value.frame, keysOnly: true)
            : expression is MethodInvocation &&
                  expression.methodName.name == 'addAll' &&
                  expression.target != null &&
                  keysOnly?.contains(
                        value.frame.unit.sources
                            .resolve(expression.target!, value.frame.unit)
                            ?.node,
                      ) ==
                      true
            ? _mapAddKeys(expression, value.frame)
            : evaluate(expression, value.frame);
        for (final outcome in outcomes) {
          final badHelper =
              outcome.value is UnknownValue &&
              value.frame.helper &&
              statement.expression is! AssignmentExpression;
          result.add(
            _Flow(
              outcome.frame,
              kind: badHelper ? _FlowKind.failed : _FlowKind.normal,
            ),
          );
        }
      }
      return _boundedFlow(result);
    }
    // Unknown loop/control flow cannot be safely expanded. In a caller only
    // values it writes or exposes are invalidated; a helper body is rejected.
    final result = [...untouched];
    for (final value in active) {
      _invalidateStatement(statement, value.frame);
      result.add(
        _Flow(
          value.frame,
          kind: value.frame.helper ? _FlowKind.failed : _FlowKind.normal,
        ),
      );
    }
    return result;
  }

  List<_Flow> _for(
    ForStatement statement,
    List<_Flow> input, {
    AstNode? stop,
    Set<AstNode>? needed,
    Set<AstNode>? keysOnly,
    required int depth,
  }) {
    if (statement.awaitKeyword != null) return _unknownLoop(statement, input);
    final parts = statement.forLoopParts;
    if (parts is ForEachParts) {
      final result = <_Flow>[];
      for (final value in input) {
        for (final iterable in _evaluateIterable(parts.iterable, value.frame)) {
          final list = iterable.value;
          if (list is! ListValue || !list.known || list.items.length > limit) {
            result.addAll(_unknownLoop(statement, [_Flow(iterable.frame)]));
            continue;
          }
          var states = [_Flow(iterable.frame)];
          final reached = <_Flow>[];
          for (final item in [...list.items]) {
            final next = <_Flow>[];
            for (final state in states) {
              if (state.kind != _FlowKind.normal &&
                  state.kind != _FlowKind.continued) {
                next.add(state);
                continue;
              }
              if (!_bindLoop(parts, item, state.frame)) {
                next.add(_Flow(state.frame, kind: _FlowKind.failed));
                continue;
              }
              if (stop != null && _contains(statement.body, stop)) {
                reached.addAll(
                  _statement(
                    statement.body,
                    [_Flow(state.frame.copy())],
                    stop: stop,
                    depth: depth + 1,
                    needed: needed,
                    keysOnly: keysOnly,
                  ).where((value) => value.kind == _FlowKind.reached),
                );
              }
              final flow = _statement(
                statement.body,
                [_Flow(state.frame)],
                depth: depth + 1,
                needed: needed,
                keysOnly: keysOnly,
              );
              next.addAll(flow);
            }
            states = _boundedFlow(next);
          }
          result.addAll(reached);
          result.addAll(
            states.map(
              (value) =>
                  value.kind == _FlowKind.broken ||
                      value.kind == _FlowKind.continued
                  ? _Flow(value.frame)
                  : value,
            ),
          );
        }
      }
      return _boundedFlow(result);
    }
    if (parts is! ForParts || parts.condition == null) {
      return _unknownLoop(statement, input);
    }
    var states = input;
    if (parts is ForPartsWithDeclarations) {
      for (final declaration in parts.variables.variables) {
        final next = <_Flow>[];
        for (final state in states) {
          for (final outcome
              in declaration.initializer == null
                  ? [_scalar(null, state.frame)]
                  : evaluate(declaration.initializer!, state.frame)) {
            outcome.frame.env[declaration] = outcome.value;
            next.add(_Flow(outcome.frame));
          }
        }
        states = next;
      }
    } else if (parts is ForPartsWithExpression &&
        parts.initialization != null) {
      states = [
        for (final state in states)
          for (final value in evaluate(parts.initialization!, state.frame))
            _Flow(value.frame),
      ];
    } else if (parts is! ForPartsWithExpression) {
      return _unknownLoop(statement, states);
    }
    final completed = <_Flow>[];
    for (
      var iteration = 0;
      iteration <= limit && states.isNotEmpty;
      iteration++
    ) {
      final next = <_Flow>[];
      for (final state in states) {
        final conditions = evaluate(parts.condition!, state.frame);
        if (conditions.length != 1 ||
            conditions.single.value is! ScalarValue ||
            (conditions.single.value as ScalarValue).value is! bool) {
          completed.addAll(_unknownLoop(statement, [state]));
          continue;
        }
        final condition = conditions.single;
        if (!((condition.value as ScalarValue).value as bool)) {
          completed.add(_Flow(condition.frame));
          continue;
        }
        if (iteration == limit) {
          completed.addAll(_unknownLoop(statement, [_Flow(condition.frame)]));
          continue;
        }
        if (stop != null && _contains(statement.body, stop)) {
          completed.addAll(
            _statement(
              statement.body,
              [_Flow(condition.frame.copy())],
              stop: stop,
              depth: depth + 1,
              needed: needed,
              keysOnly: keysOnly,
            ).where((value) => value.kind == _FlowKind.reached),
          );
        }
        final body = _statement(
          statement.body,
          [_Flow(condition.frame)],
          depth: depth + 1,
          needed: needed,
          keysOnly: keysOnly,
        );
        for (final flow in body) {
          if (flow.kind == _FlowKind.broken) {
            completed.add(_Flow(flow.frame));
            continue;
          }
          if (flow.kind != _FlowKind.normal &&
              flow.kind != _FlowKind.continued) {
            completed.add(flow);
            continue;
          }
          var updated = [flow.frame];
          for (final updater in parts.updaters) {
            updated = [
              for (final frame in updated)
                for (final value in evaluate(updater, frame)) value.frame,
            ];
          }
          next.addAll(updated.map(_Flow.new));
        }
      }
      states = _boundedFlow(next);
    }
    return _boundedFlow(completed);
  }

  bool _contains(AstNode parent, AstNode child) =>
      parent.offset <= child.offset && child.offset < parent.end;

  bool _bindLoop(ForEachParts parts, StaticValue item, StaticFrame frame) {
    final AstNode? variable = parts is ForEachPartsWithDeclaration
        ? parts.loopVariable
        : parts is ForEachPartsWithIdentifier
        ? frame.unit.sources.resolve(parts.identifier, frame.unit)?.node
        : null;
    if (variable == null) return false;
    frame.env[variable] = item;
    frame.versions[variable] = (frame.versions[variable] ?? 0) + 1;
    return true;
  }

  List<_Flow> _unknownLoop(Statement statement, List<_Flow> input) {
    for (final value in input) {
      _invalidateStatement(statement, value.frame);
    }
    return [
      for (final value in input)
        _Flow(
          value.frame,
          kind: value.frame.helper ? _FlowKind.failed : _FlowKind.normal,
        ),
    ];
  }

  List<StaticOutcome> _switchExpression(
    SwitchExpression expression,
    StaticFrame frame,
  ) {
    final result = <StaticOutcome>[];
    for (final scrutinee in evaluate(expression.expression, frame)) {
      var pending = [scrutinee.frame];
      for (final branch in expression.cases) {
        final matches = <StaticFrame>[];
        final rest = <StaticFrame>[];
        for (final state in pending) {
          final match = _pattern(
            branch.guardedPattern.pattern,
            scrutinee.value,
            state,
          );
          if (match == true) {
            matches.add(state);
          } else if (match == false) {
            rest.add(state);
          } else {
            matches.add(state.copy());
            rest.add(state.copy());
          }
        }
        final when = branch.guardedPattern.whenClause;
        if (when != null) {
          final guarded = <StaticFrame>[];
          for (final state in matches) {
            for (final condition in _branches(when.expression, state)) {
              if (condition.truth) {
                guarded.add(condition.frame);
              } else {
                rest.add(condition.frame);
              }
            }
          }
          matches.clear();
          matches.addAll(guarded);
        }
        for (final state in matches) {
          result.addAll(evaluate(branch.expression, state));
        }
        pending = rest;
        if (pending.isEmpty) break;
      }
      result.addAll(
        pending.map((state) => _unknown(state, 'non exhaustive switch')),
      );
    }
    return _bounded(result, frame);
  }

  List<_Flow> _switchStatement(
    SwitchStatement statement,
    List<_Flow> input, {
    AstNode? stop,
    Set<AstNode>? needed,
    Set<AstNode>? keysOnly,
    required int depth,
  }) {
    final result = <_Flow>[];
    for (final value in input) {
      for (final scrutinee in evaluate(statement.expression, value.frame)) {
        var pending = [scrutinee.frame];
        for (final member in statement.members) {
          final matched = <StaticFrame>[];
          final rest = <StaticFrame>[];
          for (final state in pending) {
            final bool? matches;
            if (member is SwitchDefault) {
              matches = true;
            } else if (member is SwitchCase) {
              final cases = evaluate(member.expression, state);
              matches = cases.length == 1
                  ? _equal(scrutinee.value, cases.single.value)
                  : null;
            } else if (member is SwitchPatternCase) {
              matches = _pattern(
                member.guardedPattern.pattern,
                scrutinee.value,
                state,
              );
            } else {
              matches = null;
            }
            if (matches == true) {
              matched.add(state);
            } else if (matches == false) {
              rest.add(state);
            } else {
              matched.add(state.copy());
              rest.add(state.copy());
            }
          }
          if (member is SwitchPatternCase &&
              member.guardedPattern.whenClause != null) {
            final guarded = <StaticFrame>[];
            for (final state in matched) {
              for (final branch in _branches(
                member.guardedPattern.whenClause!.expression,
                state,
              )) {
                if (branch.truth) {
                  guarded.add(branch.frame);
                } else {
                  rest.add(branch.frame);
                }
              }
            }
            matched.clear();
            matched.addAll(guarded);
          }
          if (stop != null &&
              statement.offset <= stop.offset &&
              stop.offset < statement.end &&
              !(member.offset <= stop.offset && stop.offset < member.end)) {
            pending = rest;
            continue;
          }
          var flow = matched.map(_Flow.new).toList();
          for (final child in member.statements) {
            if (stop != null && child.offset > stop.offset) break;
            flow = _statement(
              child,
              flow,
              stop: stop,
              depth: depth + 1,
              needed: needed,
              keysOnly: keysOnly,
            );
          }
          result.addAll(
            flow.map(
              (value) =>
                  value.kind == _FlowKind.broken ? _Flow(value.frame) : value,
            ),
          );
          pending = rest;
        }
        result.addAll(pending.map(_Flow.new));
      }
    }
    return _boundedFlow(result);
  }

  bool? _pattern(
    DartPattern pattern,
    StaticValue scrutinee,
    StaticFrame frame,
  ) {
    if (pattern is WildcardPattern) return true;
    if (pattern is ConstantPattern) {
      final values = evaluate(pattern.expression, frame);
      return values.length == 1 ? _equal(scrutinee, values.single.value) : null;
    }
    if (pattern is ParenthesizedPattern) {
      return _pattern(pattern.pattern, scrutinee, frame);
    }
    // Typed/binding/relational patterns require semantic type facts this
    // source interpreter does not have. Preserve both possibilities.
    return null;
  }

  List<({StaticFrame frame, bool truth})> _branches(
    Expression condition,
    StaticFrame frame,
  ) {
    final paths = conditionPaths(condition, frame, this);
    if (paths.isEmpty) {
      return [
        for (final truth in [true, false])
          (frame: _invalidateAll(frame.copy()), truth: truth),
      ];
    }
    return [for (final path in paths) (frame: path.frame, truth: path.value)];
  }

  StaticValue _binary(
    String operator,
    StaticValue left,
    StaticValue right,
    AstNode node,
    StaticFrame frame,
  ) {
    if (operator == '+' && (left is UnknownValue || right is UnknownValue)) {
      if (left is UnknownValue) _invalidate(right);
      return left is UnknownValue ? left : right;
    }
    if (operator == '+' && left is TextValue && right is TextValue) {
      return TextValue(left.text.append(right.text));
    }
    if (operator == '+' &&
        left is ListValue &&
        right is ListValue &&
        left.known &&
        right.known) {
      return ListValue([...left.items, ...right.items]);
    }
    if (operator == '==' || operator == '!=') {
      final equal = _equal(left, right);
      return equal == null
          ? UnknownValue('unknown comparison')
          : ScalarValue(operator == '==' ? equal : !equal);
    }
    if (operator == '??') {
      if (left is _SkippedNullValue) return right;
      if (left is ScalarValue && left.value == null) return right;
      return left is UnknownValue
          ? UnknownValue('unknown nullable value')
          : left;
    }
    if (left is ScalarValue && right is ScalarValue) {
      final a = left.value;
      final b = right.value;
      if (a is num && b is num) {
        return switch (operator) {
          '+' => ScalarValue(a + b),
          '-' => ScalarValue(a - b),
          '*' => ScalarValue(a * b),
          '/' => b == 0 ? UnknownValue('division by zero') : ScalarValue(a / b),
          '~/' =>
            b == 0 ? UnknownValue('division by zero') : ScalarValue(a ~/ b),
          '%' => b == 0 ? UnknownValue('division by zero') : ScalarValue(a % b),
          '<' => ScalarValue(a < b),
          '<=' => ScalarValue(a <= b),
          '>' => ScalarValue(a > b),
          '>=' => ScalarValue(a >= b),
          _ => UnknownValue('unknown numeric operation'),
        };
      }
    }
    if (left is ObjectValue || left is RecordValue || left is UnknownValue) {
      _invalidate(left);
      _invalidate(right);
    }
    return UnknownValue('unreadable operation');
  }

  bool? _equal(StaticValue left, StaticValue right) {
    final leftNull =
        left is _SkippedNullValue || left is ScalarValue && left.value == null;
    final rightNull =
        right is _SkippedNullValue ||
        right is ScalarValue && right.value == null;
    if (leftNull || rightNull) {
      // Dart does not invoke an overloaded equality operator when either
      // operand is null. Known concrete values therefore remain unaffected.
      return left is UnknownValue || right is UnknownValue
          ? null
          : leftNull && rightNull;
    }
    if (left is ScalarValue && right is ScalarValue) {
      return left.value == right.value;
    }
    if (left is TextValue && right is TextValue) {
      return left.text.text == right.text.text;
    }
    if (left is EnumValue && right is EnumValue) {
      return identical(left.type.node, right.type.node) &&
          left.index == right.index;
    }
    if (left is ObjectValue ||
        right is ObjectValue ||
        left is RecordValue ||
        right is RecordValue ||
        left is UnknownValue) {
      _invalidate(left);
      _invalidate(right);
      return null;
    }
    if (right is UnknownValue) return null;
    return identical(left, right) ? true : null;
  }

  StaticValue _prefix(String operator, StaticValue value) {
    if (value is ScalarValue) {
      final scalar = value.value;
      if (operator == '!' && scalar is bool) return ScalarValue(!scalar);
      if (operator == '-' && scalar is num) return ScalarValue(-scalar);
      if (operator == '+' && scalar is num) return ScalarValue(scalar);
      if (operator == '~' && scalar is int) return ScalarValue(~scalar);
    }
    if (value is ObjectValue || value is RecordValue) _invalidate(value);
    return UnknownValue('unknown unary operation');
  }

  List<StaticOutcome> _append(
    List<StaticOutcome> left,
    List<StaticOutcome> Function(StaticFrame) evaluateRight,
    AstNode node,
  ) {
    final values = <StaticOutcome>[];
    for (final a in left) {
      for (final b in evaluateRight(a.frame)) {
        values.add(
          StaticOutcome(_binary('+', a.value, b.value, node, b.frame), b.frame),
        );
      }
    }
    return left.isEmpty ? [] : _bounded(values, left.first.frame);
  }

  StaticValue _asText(StaticValue value, AstNode node, StaticFrame frame) {
    if (value is _SkippedNullValue) {
      return TextValue(_synthetic('null', node, frame));
    }
    if (value is TextValue) return value;
    if (value is ScalarValue) {
      return TextValue(_synthetic('${value.value}', node, frame));
    }
    return value is UnknownValue
        ? value
        : UnknownValue('unknown interpolation');
  }

  BufferValue _bufferValue(StaticValue value, AstNode node, StaticFrame frame) {
    final converted = _asText(value, node, frame);
    return BufferValue(
      converted is TextValue ? converted.text : _empty(node, frame),
    )..known = converted is TextValue;
  }

  StaticText _synthetic(String value, AstNode node, StaticFrame frame) =>
      StaticText.synthetic(value, frame.unit, node.offset);
  StaticText _empty(AstNode node, StaticFrame frame) =>
      _synthetic('', node, frame);
  StaticOutcome _scalar(Object? value, StaticFrame frame) =>
      StaticOutcome(ScalarValue(value), frame);
  StaticOutcome _unknown(
    StaticFrame frame,
    String reason, {
    String? identity,
  }) => StaticOutcome(UnknownValue(reason, identity: identity), frame);

  List<StaticOutcome> _bounded(List<StaticOutcome> values, StaticFrame frame) =>
      values.length > limit
      ? [_unknown(_invalidateAll(frame), 'variant limit')]
      : values;
  List<_Flow> _boundedFlow(List<_Flow> values) => values.length > limit
      ? [_Flow(_invalidateAll(values.first.frame), kind: _FlowKind.failed)]
      : values;

  StaticFrame _invalidateAll(StaticFrame frame) {
    for (final value in frame.env.values) {
      _invalidate(value);
    }
    for (final key in frame.env.keys.toList()) {
      // Private snapshot anchors retain their structural value so enclosing
      // evaluators can finish safely. Their mutable contents are invalidated
      // above; syntactic declarations lose their value entirely.
      if (key is AstNode) frame.env[key] = UnknownValue('evaluation limit');
    }
    return frame;
  }

  StaticValue _sharedValue(StaticValue value, [Set<StaticValue>? active]) {
    active ??= {};
    if (!active.add(value)) return UnknownValue('shared cyclic value');
    if (value is ListValue ||
        value is MapValue ||
        value is BufferValue ||
        value is BindingsValue ||
        value is IterableValue) {
      return UnknownValue('mutable global value');
    }
    if (value is ObjectValue) {
      return ObjectValue(
        value.type,
        value.fields.map(
          (name, field) => MapEntry(name, _sharedValue(field, {...active!})),
        ),
        exact: value.exact,
      );
    }
    if (value is MapEntryValue) {
      return MapEntryValue(
        _sharedValue(value.key, {...active}),
        _sharedValue(value.value, {...active}),
      );
    }
    if (value is RecordValue) {
      return RecordValue(
        [
          for (final field in value.positional)
            _sharedValue(field, {...active}),
        ],
        value.named.map(
          (name, field) => MapEntry(name, _sharedValue(field, {...active!})),
        ),
      );
    }
    return value;
  }

  void _invalidate(StaticValue value, [Set<StaticValue>? active]) {
    active ??= {};
    if (!active.add(value)) return;
    if (value is ListValue) {
      value.known = false;
      for (final item in value.items) {
        _invalidate(item, active);
      }
    }
    if (value is MapValue) {
      value.known = false;
      for (final item in value.entries.values) {
        _invalidate(item, active);
      }
    }
    if (value is BufferValue) value.known = false;
    if (value is ObjectValue) {
      final finalFields = {
        for (final field in _fields(value.type.node))
          if (field.parent is VariableDeclarationList &&
              !(field.parent as VariableDeclarationList).isLate &&
              ((field.parent as VariableDeclarationList).isFinal ||
                  (field.parent as VariableDeclarationList).isConst))
            field.name.lexeme,
      };
      for (final entry in value.fields.entries.toList()) {
        _invalidate(entry.value, active);
        if (!finalFields.contains(entry.key)) {
          value.fields[entry.key] = UnknownValue('object escaped');
        }
      }
    }
    if (value is RecordValue) {
      for (final item in value.positional) {
        _invalidate(item, active);
      }
      for (final item in value.named.values) {
        _invalidate(item, active);
      }
    }
    if (value is BindingsValue) _invalidate(value.map, active);
    if (value is IterableValue) _invalidate(value.source, active);
    if (value is MapEntryValue) {
      _invalidate(value.key, active);
      _invalidate(value.value, active);
    }
  }

  void _invalidateStatement(
    AstNode statement,
    StaticFrame frame, {
    Set<AstNode>? helpers,
    Set<StaticValue>? invalidatedValues,
  }) {
    helpers ??= {};
    invalidatedValues ??= {};
    final facts = _facts(statement);
    final calls = facts.calls;
    final readOnly = <Expression>{};
    for (final call in calls.expressions.whereType<MethodInvocation>()) {
      if (!_databaseCall(call)) continue;
      for (final argument in call.argumentList.arguments) {
        if (argument is! NamedArgument ||
            argument.name.lexeme != 'parameters') {
          continue;
        }
        final expression = argument.argumentExpression;
        if (expression is! SimpleIdentifier) continue;
        final target = frame.unit.sources.resolve(expression, frame.unit)?.node;
        final value = target == null ? null : frame.env[target];
        if (value is! BindingsValue) continue;
        // The database API reads the named keys. Parameter values may escape
        // through encoding, so mutable values still lose their known contents.
        readOnly.add(expression);
        for (final entry in value.map.entries.values) {
          _invalidate(entry, invalidatedValues);
        }
      }
    }
    final mutations = facts.writes;
    final targets = <AstNode>{};
    for (final root in _references(statement, frame.unit)) {
      if (readOnly.contains(root.expression)) continue;
      final target = root.target;
      if (target != null && !targets.add(target)) continue;
      final value = target == null ? null : frame.env[target];
      if (value != null) _invalidate(value, invalidatedValues);
      if (target is MethodDeclaration && !target.isStatic) {
        final receiver = frame.receiver;
        if (receiver != null) _invalidate(receiver, invalidatedValues);
      }
    }
    if (mutations.implicitReceiver) {
      final receiver = frame.receiver;
      if (receiver != null) _invalidate(receiver, invalidatedValues);
    }
    Set<AstNode> referenced(Expression expression) {
      return {
        for (final root in _references(expression, frame.unit))
          if (!readOnly.contains(root.expression))
            if (root.target case final node?) node,
      };
    }

    for (final expression in mutations.targets) {
      for (final target in referenced(expression)) {
        final value = frame.env[target];
        if (value != null) _invalidate(value, invalidatedValues);
        frame.invalidated.add(target);
        frame.env[target] = UnknownValue('unknown control-flow mutation');
        frame.versions[target] = (frame.versions[target] ?? 0) + 1;
      }
    }
    for (final expression in mutations.escapes) {
      if (readOnly.contains(expression)) continue;
      // Merely collecting lexical roots cannot execute helpers or construct
      // arbitrary objects. Missing values are blocked from re-reading a stale
      // initializer; existing mutable aliases are invalidated in place.
      for (final target in referenced(expression)) {
        final value = frame.env[target];
        if (value == null) {
          frame.invalidated.add(target);
        } else {
          _invalidate(value, invalidatedValues);
        }
      }
    }
    for (final declaration in _helpers(statement, frame.unit)) {
      final node = declaration.node;
      final body = _helperBody(node);
      if (body == null || !helpers.add(node)) continue;
      if (helpers.length > limit) {
        _invalidateAll(frame);
        return;
      }
      // A discarded helper result can carry a captured mutable alias even
      // when its arguments contain none. Follow readable bodies for effects
      // and returned references without interpreting their control flow.
      _invalidateStatement(
        body,
        frame.withUnit(declaration.unit),
        helpers: helpers,
        invalidatedValues: invalidatedValues,
      );
    }
  }

  bool _databaseCall(MethodInvocation call) {
    if (call.methodName.name != 'unsafeQuery' &&
        call.methodName.name != 'unsafeExecute') {
      return false;
    }
    final target = call.target;
    return target is PropertyAccess && target.propertyName.name == 'db' ||
        target is PrefixedIdentifier && target.identifier.name == 'db';
  }

  FunctionBody? _helperBody(AstNode node) => node is FunctionDeclaration
      ? node.functionExpression.body
      : node is MethodDeclaration
      ? node.body
      : node is ConstructorDeclaration
      ? node.body
      : null;

  String _identity(Expression expression, StaticFrame frame) {
    final target = frame.unit.sources.resolve(expression, frame.unit)?.node;
    return target == null
        ? '${frame.unit.path}:${expression.offset}'
        : '${frame.unit.path}:${target.offset}:${frame.versions[target] ?? 0}';
  }
}

enum _FlowKind { normal, returned, broken, continued, reached, failed }

final class _Flow {
  _Flow(this.frame, {this.kind = _FlowKind.normal, this.value});
  final StaticFrame frame;
  final _FlowKind kind;
  final StaticValue? value;
}

/// These summaries depend only on the immutable parsed AST, never a frame.
final class _AstFacts {
  _AstFacts(this.node);
  final AstNode node;
  late final writes = _scan(node, _Writes());
  late final roots = _scan(node, _ReferenceRoots());
  late final calls = _scan(node, _Invocations());
  late final captured = _scan(node, _CapturedMutations());
  late final bindings = _scan(node, _CallableBindings());
  late final returns = _scan(node, _PredicateReturns());
}

T _scan<T extends AstVisitor<void>>(AstNode node, T visitor) {
  node.accept(visitor);
  return visitor;
}

final class _Writes extends RecursiveAstVisitor<void> {
  bool implicitReceiver = false;
  final targets = <Expression>[];
  final escapes = <Expression>[];
  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    targets.add(
      left is IndexExpression && left.target != null ? left.target! : left,
    );
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (node.operator.lexeme == '++' || node.operator.lexeme == '--') {
      targets.add(node.operand);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (node.operator.lexeme == '++' || node.operator.lexeme == '--') {
      targets.add(node.operand);
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null ||
        node.target is ThisExpression ||
        node.isCascaded) {
      implicitReceiver = true;
    }
    if (node.target != null) escapes.add(node.target!);
    escapes.addAll(
      node.argumentList.arguments.map(
        (argument) => argument.argumentExpression,
      ),
    );
    super.visitMethodInvocation(node);
  }
}

final class _CapturedMutations extends RecursiveAstVisitor<void> {
  final closures = <({FunctionExpression expression, _Writes writes})>[];
  @override
  void visitFunctionExpression(FunctionExpression node) {
    final writes = _Writes();
    node.accept(writes);
    closures.add((expression: node, writes: writes));
  }

  Set<AstNode> targets(DartUnit unit) => {
    for (final closure in closures)
      for (final expression in [
        ...closure.writes.targets,
        ...closure.writes.escapes,
      ])
        if (unit.sources.resolve(expression, unit)?.node case final node?)
          // A closure's own parameters and locals are not captured state.
          // Each readable callback binds those parameters when it is invoked.
          if (node.offset < closure.expression.offset ||
              node.end > closure.expression.end)
            node,
  };
}

final class _CallableBindings extends RecursiveAstVisitor<void> {
  final nodes = <AstNode>{};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    nodes.add(node);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitRegularFormalParameter(RegularFormalParameter node) {
    nodes.add(node);
    super.visitRegularFormalParameter(node);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    nodes.add(node);
    super.visitFieldFormalParameter(node);
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    nodes.add(node);
    super.visitSuperFormalParameter(node);
  }
}

final class _ReferenceRoots extends RecursiveAstVisitor<void> {
  final expressions = <Expression>[];
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final parent = node.parent;
    if (!(parent is PropertyAccess && identical(parent.propertyName, node)) &&
        !(parent is PrefixedIdentifier && identical(parent.identifier, node)) &&
        !(parent is MethodInvocation && identical(parent.methodName, node))) {
      expressions.add(node);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    expressions.add(node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    expressions.add(node);
    super.visitPropertyAccess(node);
  }
}

final class _Invocations extends RecursiveAstVisitor<void> {
  final expressions = <Expression>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    expressions.add(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    expressions.add(node.function);
    super.visitFunctionExpressionInvocation(node);
  }
}

final class _SkippedNullValue extends StaticValue {}

final class _NoSelectionValue extends StaticValue {}

final class _CallbackReceiverReads extends RecursiveAstVisitor<void> {
  _CallbackReceiverReads(this.unit);
  final DartUnit unit;
  bool found = false;
  @override
  void visitThisExpression(ThisExpression node) {
    found = true;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = unit.sources.resolve(node, unit)?.node;
    if (target is MethodDeclaration && !target.isStatic ||
        target is FunctionDeclaration &&
            target.parent is FunctionDeclarationStatement) {
      found = true;
    }
    super.visitMethodInvocation(node);
  }
}

final class _PredicateReturns extends RecursiveAstVisitor<void> {
  final values = <Expression>[];

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression case final expression?) values.add(expression);
    super.visitReturnStatement(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}
