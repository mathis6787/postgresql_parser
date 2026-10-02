import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'string_references.dart';

/// Follows a local value through straight-line statements and finite branches.
/// Unknown writes, loops, and captured mutations invalidate the value. Reads of
/// strings cannot mutate them; reads of a map can let the map escape to a caller.
T? localValueAt<T>({
  required VariableDeclaration declaration,
  required AstNode use,
  required StringReferences references,
  required T? initial,
  required ({T? value})? Function(Statement, T?) update,
  required T? Function(T?, T?) merge,
  bool mutableObject = false,
}) {
  final statement = declaration.parent?.parent;
  final block = statement?.parent;
  if (statement is! VariableDeclarationStatement || block is! Block) {
    return null;
  }
  if (use.offset <= declaration.end || use.offset >= block.end) return null;
  AstNode? owner = use;
  while (owner != null && !identical(owner, block)) {
    if (owner is FunctionExpression || owner is MethodDeclaration) return null;
    owner = owner.parent;
  }
  if (owner == null) return null;

  bool matches(Expression expression) =>
      identical(references.targetFor(expression), declaration);
  final captured = _CapturedUse(matches, mutableObject);
  block.accept(captured);
  if (captured.found) return null;

  bool touches(AstNode node, {bool containingUse = false}) {
    final visitor = _LocalUse(
      matches,
      mutableObject,
      ignoreReadsFrom: containingUse ? use.offset : null,
    );
    node.accept(visitor);
    return visitor.found;
  }

  _Flow<T>? follow(Statement node, T? value, int depth) {
    if (depth >= 32) return null;
    final containsUse = node.offset <= use.offset && use.offset < node.end;
    if (node is Block) {
      for (final child in node.statements) {
        if (child.end <= declaration.end) continue;
        final next = follow(child, value, depth + 1);
        if (next == null) return null;
        value = next.value;
        if (next.reached || !next.fallsThrough) return next;
      }
      return _Flow(value);
    }
    if (node is IfStatement) {
      if (touches(node.expression)) return null;
      if (containsUse) {
        if (node.thenStatement.offset <= use.offset &&
            use.offset < node.thenStatement.end) {
          return follow(node.thenStatement, value, depth + 1);
        }
        final otherwise = node.elseStatement;
        if (otherwise != null && otherwise.offset <= use.offset) {
          return follow(otherwise, value, depth + 1);
        }
        return _Flow(value, reached: true);
      }
      final condition = node.expression;
      if (condition is BooleanLiteral && node.caseClause == null) {
        final selected = condition.value
            ? node.thenStatement
            : node.elseStatement;
        return selected == null
            ? _Flow(value)
            : follow(selected, value, depth + 1);
      }
      final yes = follow(node.thenStatement, value, depth + 1);
      final no = node.elseStatement == null
          ? _Flow<T>(value)
          : follow(node.elseStatement!, value, depth + 1);
      if (yes == null || no == null) return null;
      if (!yes.fallsThrough) return no;
      if (!no.fallsThrough) return yes;
      return _Flow(merge(yes.value, no.value));
    }
    if (containsUse) {
      // A containing loop can have earlier iterations; do not assume its entry
      // value applies to the call. Other containing statements must not write.
      if (node is ForStatement ||
          node is WhileStatement ||
          node is DoStatement ||
          node is SwitchStatement ||
          node is TryStatement ||
          touches(node, containingUse: true)) {
        return null;
      }
      return _Flow(value, reached: true);
    }
    final changed = update(node, value);
    if (changed != null) return _Flow(changed.value);
    if (touches(node)) return null;
    if (node is ReturnStatement ||
        (node is ExpressionStatement && node.expression is ThrowExpression)) {
      return _Flow(value, fallsThrough: false);
    }
    return _Flow(value);
  }

  final result = follow(block, initial, 0);
  return result != null && result.reached ? result.value : null;
}

final class _Flow<T> {
  _Flow(this.value, {this.reached = false, this.fallsThrough = true});
  final T? value;
  final bool reached;
  final bool fallsThrough;
}

final class _LocalUse extends RecursiveAstVisitor<void> {
  _LocalUse(this.matches, this.mutableObject, {this.ignoreReadsFrom});
  final bool Function(Expression) matches;
  final bool mutableObject;
  final int? ignoreReadsFrom;
  bool found = false;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (mutableObject &&
        (ignoreReadsFrom == null || node.offset < ignoreReadsFrom!) &&
        matches(node)) {
      found = true;
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (matches(node.leftHandSide)) found = true;
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if ((node.operator.lexeme == '++' || node.operator.lexeme == '--') &&
        matches(node.operand)) {
      found = true;
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (matches(node.operand)) found = true;
    super.visitPostfixExpression(node);
  }
}

final class _CapturedUse extends RecursiveAstVisitor<void> {
  _CapturedUse(this.matches, this.mutableObject);
  final bool Function(Expression) matches;
  final bool mutableObject;
  bool found = false;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    final visitor = _LocalUse(matches, mutableObject);
    node.accept(visitor);
    found |= visitor.found;
    // The nested visitor already inspects every closure below this one.
  }
}
