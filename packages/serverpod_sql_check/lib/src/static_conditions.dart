import 'package:analyzer/dart/ast/ast.dart';

import 'static_value.dart';

typedef ConditionPath = ({StaticFrame frame, bool value});
int _occurrence = 0;

/// Repeated readable conditions share a predicate only while their referenced
/// values have not changed. Calls/getters remain independent observations.
List<ConditionPath> conditionPaths(
  Expression expression,
  StaticFrame frame,
  StaticRuntime runtime,
) {
  if (expression is ParenthesizedExpression) {
    return conditionPaths(expression.expression, frame, runtime);
  }
  if (expression is PrefixExpression && expression.operator.lexeme == '!') {
    return [
      for (final path in conditionPaths(expression.operand, frame, runtime))
        (frame: path.frame, value: !path.value),
    ];
  }
  if (expression is BinaryExpression &&
      (expression.operator.lexeme == '&&' ||
          expression.operator.lexeme == '||')) {
    final and = expression.operator.lexeme == '&&';
    final results = <ConditionPath>[];
    for (final left in conditionPaths(expression.leftOperand, frame, runtime)) {
      if (left.value != and) {
        results.add(left);
      } else {
        results.addAll(
          conditionPaths(expression.rightOperand, left.frame, runtime),
        );
      }
      if (results.length > 32) return [];
    }
    return results;
  }
  final result = <ConditionPath>[];
  for (final outcome in runtime.evaluate(expression, frame)) {
    final value = outcome.value;
    if (value is ScalarValue && value.value is bool) {
      result.add((frame: outcome.frame, value: value.value as bool));
      continue;
    }
    final atom = _atom(expression, outcome.frame, value);
    final prior = outcome.frame.conditions[atom.key];
    if (prior != null) {
      result.add((frame: outcome.frame, value: prior != atom.inverted));
    } else {
      for (final truth in [true, false]) {
        final branch = outcome.frame.copy();
        branch.conditions[atom.key] = truth;
        result.add((frame: branch, value: truth != atom.inverted));
      }
    }
    if (result.length > 32) return [];
  }
  return result;
}

({String key, bool inverted}) _atom(
  Expression expression,
  StaticFrame frame,
  StaticValue value,
) {
  if (expression is BinaryExpression) {
    var operator = expression.operator.lexeme;
    if (const {'==', '!=', '<', '>=', '>', '<='}.contains(operator)) {
      final left = _identity(expression.leftOperand, frame);
      final right = _identity(expression.rightOperand, frame);
      final equality = operator == '==' || operator == '!=';
      final safeNullEquality =
          equality &&
          (_isNull(expression.leftOperand, frame) ||
              _isNull(expression.rightOperand, frame));
      final primitiveOperands =
          _knownPrimitive(expression.leftOperand, frame) &&
          _knownPrimitive(expression.rightOperand, frame);
      // Identical object references do not make overloaded operators stable.
      // A custom == or ordering operator can observe or mutate runtime state.
      // Unknown numeric values can also be NaN, for which >= is not !<.
      if (left != null &&
          right != null &&
          (safeNullEquality || primitiveOperands)) {
        final operands = [left, right];
        var inverted = false;
        if (operator == '==' || operator == '!=') {
          operands.sort();
          inverted = operator == '!=';
          operator = '==';
        } else if (operator == '>=' || operator == '<=') {
          inverted = true;
          operator = operator == '>=' ? '<' : '>';
        }
        return (
          key: '${operands[0]}$operator${operands[1]}',
          inverted: inverted,
        );
      }
    }
  }
  final identity = _identity(expression, frame);
  if (identity != null) return (key: identity, inverted: false);
  // A constructor-backed immutable field can carry the primitive value's
  // identity, even though arbitrary runtime property access cannot.
  if (value is UnknownValue &&
      value.identity != null &&
      expression is! MethodInvocation) {
    final root = expression is PrefixedIdentifier
        ? expression.prefix
        : expression is PropertyAccess
        ? expression.target
        : null;
    final declaration = root == null
        ? null
        : frame.unit.sources.resolve(root, frame.unit)?.node;
    if (declaration != null && frame.env[declaration] is ObjectValue) {
      return (key: value.identity!, inverted: false);
    }
  }
  return (key: 'observation:${_occurrence++}', inverted: false);
}

bool _isNull(Expression expression, StaticFrame frame) {
  final value = _knownValue(expression, frame);
  return value is ScalarValue && value.value == null;
}

bool _knownPrimitive(Expression expression, StaticFrame frame) {
  final value = _knownValue(expression, frame);
  return value is ScalarValue || value is TextValue || value is EnumValue;
}

StaticValue? _knownValue(Expression expression, StaticFrame frame) {
  if (expression is ParenthesizedExpression) {
    return _knownValue(expression.expression, frame);
  }
  if (expression is NullLiteral) return ScalarValue(null);
  if (expression is BooleanLiteral) return ScalarValue(expression.value);
  if (expression is IntegerLiteral) return ScalarValue(expression.value);
  if (expression is DoubleLiteral) return ScalarValue(expression.value);
  if (expression is SimpleStringLiteral) {
    return TextValue(
      StaticText.synthetic(expression.value, frame.unit, expression.offset),
    );
  }
  if (expression is! SimpleIdentifier) return null;
  final target = frame.unit.sources.resolve(expression, frame.unit)?.node;
  return target == null || frame.invalidated.contains(target)
      ? null
      : frame.env[target];
}

String? _identity(Expression expression, StaticFrame frame) {
  if (expression is ParenthesizedExpression) {
    return _identity(expression.expression, frame);
  }
  if (expression is NullLiteral) return 'literal:null';
  if (expression is BooleanLiteral) return 'literal:${expression.value}';
  if (expression is IntegerLiteral ||
      expression is DoubleLiteral ||
      expression is SimpleStringLiteral) {
    return 'literal:${expression.toSource()}';
  }
  if (expression is! SimpleIdentifier) return null;
  final target = frame.unit.sources.resolve(expression, frame.unit);
  if (target == null) return null;
  final node = target.node;
  if (frame.invalidated.contains(node)) return null;
  final value = frame.env[node];
  if (value is UnknownValue && value.identity != null) return value.identity;
  if (node is FormalParameter ||
      (node is VariableDeclaration &&
          node.parent?.parent is VariableDeclarationStatement)) {
    return '${target.unit.path}:${node.offset}:${frame.versions[node] ?? 0}';
  }
  return null;
}
