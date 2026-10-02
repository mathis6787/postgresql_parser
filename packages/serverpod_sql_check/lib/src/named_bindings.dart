import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'dart_sources.dart';
import 'local_flow.dart';

// Conditional keys are possible, but are not guaranteed to exist. This avoids
// treating a matching conditional key as proof, or reporting it as missing.
final class NamedBindings {
  NamedBindings(this.keys, {Set<String>? possible})
    : possible = possible ?? keys;
  final Set<String>? keys;
  final Set<String>? possible;
}

NamedBindings _unionKeys(NamedBindings left, NamedBindings right) =>
    NamedBindings(
      {...left.keys!, ...right.keys!},
      possible: {...left.possible!, ...right.possible!},
    );

NamedBindings? _branchKeys(NamedBindings? left, NamedBindings? right) =>
    left == null || right == null
    ? null
    : NamedBindings(
        left.keys!.intersection(right.keys!),
        possible: {...left.possible!, ...right.possible!},
      );

NamedBindings namedBindings(
  Expression? expression,
  DartUnit unit,
  List<String>? Function(Expression, DartUnit) strings,
) => _BindingResolver(strings).resolve(expression, unit);

final class _BindingResolver {
  _BindingResolver(this._strings);
  final List<String>? Function(Expression, DartUnit) _strings;
  NamedBindings resolve(Expression? expression, DartUnit unit) {
    while (expression is ParenthesizedExpression) {
      expression = expression.expression;
    }
    if (expression == null || expression is NullLiteral) {
      return NamedBindings({});
    }
    ArgumentList? arguments;
    if (expression is InstanceCreationExpression) {
      // Before resolution, `new QueryParameters.named` can look like an import
      // prefix and a type called `named`, rather than a named constructor.
      final name = expression.constructorName.toSource();
      if (name == 'QueryParameters.named' ||
          name.endsWith('.QueryParameters.named')) {
        arguments = expression.argumentList;
      }
    } else if (expression is MethodInvocation &&
        expression.methodName.name == 'named') {
      final target = expression.target;
      if ((target is SimpleIdentifier && target.name == 'QueryParameters') ||
          (target is PrefixedIdentifier &&
              target.identifier.name == 'QueryParameters')) {
        arguments = expression.argumentList;
      }
    }
    if (arguments == null || arguments.arguments.length != 1) {
      return NamedBindings(null);
    }
    return _mapKeys(arguments.arguments.single.argumentExpression, unit, {}) ??
        NamedBindings(null);
  }

  NamedBindings? _mapKeys(
    Expression expression,
    DartUnit unit,
    Set<AstNode> active, {
    bool retaining = false,
  }) {
    if (!unit.readable || active.length >= 32) return null;
    if (expression is ParenthesizedExpression) {
      return _mapKeys(
        expression.expression,
        unit,
        active,
        retaining: retaining,
      );
    }
    if (expression is ConditionalExpression) {
      final condition = expression.condition;
      if (condition is BooleanLiteral) {
        return _mapKeys(
          condition.value
              ? expression.thenExpression
              : expression.elseExpression,
          unit,
          active,
          retaining: retaining,
        );
      }
      return _branchKeys(
        _mapKeys(expression.thenExpression, unit, active, retaining: retaining),
        _mapKeys(expression.elseExpression, unit, active, retaining: retaining),
      );
    }
    if (expression is SimpleIdentifier ||
        expression is PrefixedIdentifier ||
        expression is PropertyAccess) {
      final target = unit.sources.resolve(expression, unit);
      final variable = target?.node;
      if (target == null ||
          variable is! VariableDeclaration ||
          !active.add(variable)) {
        return null;
      }
      try {
        final list = variable.parent;
        if (list is! VariableDeclarationList ||
            list.isLate ||
            variable.initializer == null) {
          return null;
        }
        if (!list.isConst && retaining) return null;
        final initial = _mapKeys(
          variable.initializer!,
          target.unit,
          active,
          retaining: true,
        );
        if (list.isConst) return initial;
        // Mutable maps must stay local: imports, fields, aliases, and escaped maps
        // can be changed by code whose effects this checker cannot establish.
        if (!identical(unit, target.unit)) return null;
        return localValueAt<NamedBindings>(
          declaration: variable,
          use: expression,
          references: unit.references,
          initial: initial,
          mutableObject: true,
          merge: _branchKeys,
          update: (statement, value) {
            if (statement is! ExpressionStatement) return null;
            final operation = statement.expression;
            bool isMap(Expression? node) =>
                node != null &&
                identical(unit.references.targetFor(node), variable);
            if (operation is AssignmentExpression &&
                isMap(operation.leftHandSide)) {
              return (
                value: operation.operator.lexeme == '='
                    ? _mapKeys(
                        operation.rightHandSide,
                        unit,
                        active,
                        retaining: true,
                      )
                    : null,
              );
            }
            if (operation is AssignmentExpression &&
                operation.leftHandSide is IndexExpression) {
              final index = operation.leftHandSide as IndexExpression;
              if (!isMap(index.target)) return null;
              if (operation.operator.lexeme != '=' ||
                  value == null ||
                  _usesVariable(operation.rightHandSide, variable, unit)) {
                return (value: null);
              }
              final key = _strings(index.index, unit);
              if (key == null || key.length != 1) return (value: null);
              return (value: _unionKeys(value, NamedBindings({key.single})));
            }
            if (operation is MethodInvocation && isMap(operation.target)) {
              if (value == null) return (value: null);
              final args = operation.argumentList.arguments;
              switch (operation.methodName.name) {
                case 'clear':
                  return (value: args.isEmpty ? NamedBindings({}) : null);
                case 'addAll':
                  if (args.length != 1) return (value: null);
                  if (_usesVariable(args.single, variable, unit)) {
                    return (value: null);
                  }
                  final extra = _mapKeys(
                    args.single.argumentExpression,
                    unit,
                    active,
                  );
                  return (
                    value: extra == null ? null : _unionKeys(value, extra),
                  );
                case 'remove':
                  if (args.length != 1) return (value: null);
                  final key = _strings(args.single.argumentExpression, unit);
                  if (key == null || key.length != 1) return (value: null);
                  return (
                    value: NamedBindings(
                      {...value.keys!}..remove(key.single),
                      possible: {...value.possible!}..remove(key.single),
                    ),
                  );
                default:
                  return (value: null);
              }
            }
            return null;
          },
        );
      } finally {
        active.remove(variable);
      }
    }
    if (expression is! SetOrMapLiteral) return null;
    NamedBindings? entryKeys(CollectionElement entry) {
      if (entry is MapLiteralEntry) {
        final variants = _strings(entry.key, unit);
        return variants == null || variants.length != 1
            ? null
            : NamedBindings({variants.single});
      }
      if (entry is SpreadElement) {
        if (entry.isNullAware && entry.expression is NullLiteral) {
          return NamedBindings({});
        }
        return _mapKeys(entry.expression, unit, active);
      }
      if (entry is IfElement) {
        final condition = entry.expression;
        if (condition is BooleanLiteral && entry.caseClause == null) {
          final selected = condition.value
              ? entry.thenElement
              : entry.elseElement;
          return selected == null ? NamedBindings({}) : entryKeys(selected);
        }
        return _branchKeys(
          entryKeys(entry.thenElement),
          entry.elseElement == null
              ? NamedBindings({})
              : entryKeys(entry.elseElement!),
        );
      }
      return null;
    }

    var result = NamedBindings({});
    for (final entry in expression.elements) {
      final keys = entryKeys(entry);
      if (keys == null) return null;
      result = _unionKeys(result, keys);
    }
    return result;
  }

  bool _usesVariable(
    AstNode node,
    VariableDeclaration variable,
    DartUnit unit,
  ) {
    final visitor = _VariableReads(variable, unit);
    node.accept(visitor);
    return visitor.found;
  }
}

final class _VariableReads extends RecursiveAstVisitor<void> {
  _VariableReads(this.variable, this.unit);
  final VariableDeclaration variable;
  final DartUnit unit;
  bool found = false;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    found |= identical(unit.references.targetFor(node), variable);
    super.visitSimpleIdentifier(node);
  }
}
