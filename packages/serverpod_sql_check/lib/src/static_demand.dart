import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'dart_sources.dart';

/// Local dependencies that can affect SQL text or parameter-map keys.
/// Unrelated runtime values are still inspected for effects by the evaluator,
/// but their possible return values need not multiply query paths.
final class StaticDemand {
  StaticDemand(Expression sql, Expression? parameters, this.unit) {
    Block? block;
    for (AstNode? owner = sql.parent; owner != null; owner = owner.parent) {
      if (owner is BlockFunctionBody) {
        block = owner.block;
        break;
      }
      if (owner is ExpressionFunctionBody) break;
    }
    if (block == null) return;
    final index = _DemandIndex(sql.offset);
    block.accept(index);
    _full(sql);
    if (parameters != null) {
      final expression = _unwrap(parameters);
      if (expression is MethodInvocation &&
          expression.methodName.name == 'named' &&
          expression.argumentList.arguments.length == 1) {
        _keys(expression.argumentList.arguments.single.argumentExpression);
      } else if (expression is InstanceCreationExpression &&
          expression.constructorName.name?.name == 'named' &&
          expression.argumentList.arguments.length == 1) {
        _keys(expression.argumentList.arguments.single.argumentExpression);
      } else {
        _full(expression);
      }
    }
    final processed = <AstNode, int>{};
    for (var pass = 0; pass < 32; pass++) {
      final before = _modes.entries
          .map((entry) => (entry.key, entry.value))
          .toSet();
      // A write through an otherwise unused alias can still change a needed
      // collection. Retain every lexical alias, including forward chains.
      for (final variable in index.variables) {
        if (_modes.containsKey(variable)) continue;
        final initializer = variable.initializer;
        if (initializer == null) continue;
        final expression = _unwrap(initializer);
        if (expression is SimpleIdentifier ||
            expression is PrefixedIdentifier ||
            expression is PropertyAccess ||
            expression is IndexExpression) {
          final modes = _references(expression)
              .map((declaration) => _modes[declaration])
              .whereType<int>();
          if (modes.isNotEmpty) {
            _modes[variable] = modes.contains(2) ? 2 : 1;
          }
        }
      }
      for (final variable in index.variables) {
        final mode = _modes[variable];
        if (mode == null || processed[variable] == mode) continue;
        processed[variable] = mode;
        final initializer = variable.initializer;
        if (initializer != null) {
          mode == 1 ? _keys(initializer) : _full(initializer);
        }
      }
      for (final entry in _modes.entries.toList()) {
        if (processed[entry.key] == entry.value) continue;
        final declaration = entry.key;
        if (declaration is FunctionDeclaration) {
          processed[declaration] = entry.value;
          _full(declaration.functionExpression.body);
        } else if (declaration is MethodDeclaration) {
          processed[declaration] = entry.value;
          _full(declaration.body);
        }
      }
      for (final assignment in index.assignments) {
        final left = assignment.leftHandSide;
        final target = left is IndexExpression ? left.target : left;
        final declaration = target == null
            ? null
            : unit.references.targetFor(target);
        if (declaration != null && left is! IndexExpression) {
          final right = _unwrap(assignment.rightHandSide);
          if (right is SimpleIdentifier ||
              right is PrefixedIdentifier ||
              right is PropertyAccess ||
              right is IndexExpression) {
            final modes = _references(right)
                .map((node) => _modes[node])
                .whereType<int>();
            if (modes.isNotEmpty) {
              final aliasMode = modes.contains(2) ? 2 : 1;
              if ((_modes[declaration] ?? 0) < aliasMode) {
                _modes[declaration] = aliasMode;
              }
            }
          }
        }
        final mode = _modes[declaration];
        if (mode == null) continue;
        if (left is IndexExpression) {
          _full(left.index);
          if (mode == 2) _full(assignment.rightHandSide);
        } else {
          mode == 1
              ? _keys(assignment.rightHandSide)
              : _full(assignment.rightHandSide);
        }
      }
      for (final call in index.calls) {
        final target = call.target;
        final mode = target == null
            ? null
            : _modes[unit.references.targetFor(target)];
        if (mode == null) continue;
        for (final argument in call.argumentList.arguments) {
          if (mode == 1 && call.methodName.name == 'addAll') {
            _keys(argument.argumentExpression);
          } else {
            _full(argument.argumentExpression);
          }
        }
      }
      for (final control in index.controls) {
        if (control.offset <= sql.offset && sql.offset < control.end ||
            _references(control).any(_modes.containsKey) ||
            _terminates(control)) {
          if (control is IfStatement) _full(control.expression);
          if (control is SwitchStatement) _full(control.expression);
          if (control is WhileStatement) _full(control.condition);
          if (control is DoStatement) _full(control.condition);
          if (control is ForStatement) _full(control.forLoopParts);
        }
      }
      if (_modes.length == before.length &&
          _modes.entries.every(
            (entry) => before.contains((entry.key, entry.value)),
          )) {
        return;
      }
    }
    // Dependency expansion must never certify a truncated slice.
    for (final variable in index.variables) {
      _modes[variable] = 2;
    }
  }

  final DartUnit unit;
  final _modes = <AstNode, int>{};
  Set<AstNode> get needed => _modes.keys.toSet();
  Set<AstNode> get keysOnly => {
    for (final entry in _modes.entries)
      if (entry.value == 1) entry.key,
  };

  Expression _unwrap(Expression expression) {
    while (expression is ParenthesizedExpression) {
      expression = expression.expression;
    }
    return expression;
  }

  void _full(AstNode node) {
    for (final declaration in _references(node)) {
      _modes[declaration] = 2;
    }
  }

  void _keys(Expression expression) {
    expression = _unwrap(expression);
    if (expression is SimpleIdentifier) {
      final declaration = unit.references.targetFor(expression);
      if (declaration != null) _modes.putIfAbsent(declaration, () => 1);
    } else if (expression is SetOrMapLiteral) {
      for (final element in expression.elements) {
        _keyElement(element);
      }
    } else if (expression is ConditionalExpression) {
      _full(expression.condition);
      _keys(expression.thenExpression);
      _keys(expression.elseExpression);
    } else {
      _full(expression);
    }
  }

  void _keyElement(CollectionElement element) {
    if (element is MapLiteralEntry) {
      _full(element.key);
    } else if (element is SpreadElement) {
      _keys(element.expression);
    } else if (element is IfElement) {
      _full(element.expression);
      _keyElement(element.thenElement);
      if (element.elseElement != null) _keyElement(element.elseElement!);
    } else {
      _full(element);
    }
  }

  Set<AstNode> _references(AstNode node) {
    final collector = _DemandReferences(unit);
    node.accept(collector);
    return collector.declarations;
  }

  bool _terminates(AstNode node) {
    final collector = _DemandTermination();
    node.accept(collector);
    return collector.found;
  }
}

final class _DemandReferences extends RecursiveAstVisitor<void> {
  _DemandReferences(this.unit);
  final DartUnit unit;
  final declarations = <AstNode>{};
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final declaration = unit.references.targetFor(node);
    if (declaration is FunctionDeclaration ||
        declaration is MethodDeclaration) {
      declarations.add(declaration!);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final parent = node.parent;
    if (parent is PropertyAccess && identical(parent.propertyName, node) ||
        parent is PrefixedIdentifier && identical(parent.identifier, node) ||
        parent is MethodInvocation && identical(parent.methodName, node)) {
      return;
    }
    final declaration = unit.references.targetFor(node);
    if (declaration != null) declarations.add(declaration);
  }
}

final class _DemandIndex extends RecursiveAstVisitor<void> {
  _DemandIndex(this.end);
  final int end;
  final variables = <VariableDeclaration>[];
  final assignments = <AssignmentExpression>[];
  final calls = <MethodInvocation>[];
  final controls = <Statement>[];
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.offset < end) variables.add(node);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (node.offset < end) assignments.add(node);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.offset < end) calls.add(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    if (node.offset < end) controls.add(node);
    super.visitIfStatement(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    if (node.offset < end) controls.add(node);
    super.visitSwitchStatement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    if (node.offset < end) controls.add(node);
    super.visitForStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    if (node.offset < end) controls.add(node);
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    if (node.offset < end) controls.add(node);
    super.visitDoStatement(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

final class _DemandTermination extends RecursiveAstVisitor<void> {
  bool found = false;
  @override
  void visitReturnStatement(ReturnStatement node) {
    found = true;
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    found = true;
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}
