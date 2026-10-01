/// Lexical lookup for immutable string initializers in one Dart file.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Resolves same-file const/final declarations without executing Dart code.
///
/// Every declaration, including runtime parameters and mutable variables, is
/// indexed so an inner name can prevent lookup of an unrelated outer constant.
final class StringReferences {
  /// Indexes declarations before SQL extraction, including forward globals.
  StringReferences(CompilationUnit unit) {
    unit.accept(_Declarations(this));
  }

  final _scopes = <AstNode, Map<String, _Binding>>{};
  final _classes = <String, ClassDeclaration>{};

  /// Returns a safely readable initializer's declaration, or null if unknown.
  ///
  /// Local declarations must precede their use. Imported values, getters,
  /// mutable variables, late values, and runtime parameters are not resolved.
  VariableDeclaration? declarationFor(Expression reference) {
    _Binding? binding;
    if (reference is SimpleIdentifier) {
      binding = _lookup(reference.name, reference);
    } else if (reference is PrefixedIdentifier) {
      binding = _classField(
        reference.prefix.name,
        reference.identifier.name,
        reference,
      );
    } else if (reference is PropertyAccess &&
        reference.target is ThisExpression) {
      for (AstNode? node = reference.parent; node != null; node = node.parent) {
        if (node is ClassDeclaration) {
          binding = _scopes[node]?[reference.propertyName.name];
          break;
        }
      }
    } else if (reference is PropertyAccess &&
        reference.target is SimpleIdentifier) {
      binding = _classField(
        (reference.target as SimpleIdentifier).name,
        reference.propertyName.name,
        reference,
      );
    }
    final declaration = binding?.declaration;
    if (declaration == null) return null;
    final list = declaration.parent;
    if (list is! VariableDeclarationList ||
        (!list.isConst && !list.isFinal) ||
        list.isLate ||
        declaration.initializer == null) {
      return null;
    }
    if (binding!.local && reference.offset < declaration.offset) return null;
    return declaration;
  }

  _Binding? _classField(String className, String fieldName, AstNode use) {
    // A local variable or parameter called ClassName shadows the actual class.
    if (_lookup(className, use) != null) return null;
    final owner = _classes[className];
    final binding = _scopes[owner]?[fieldName];
    final field = binding?.declaration?.parent?.parent;
    return field is FieldDeclaration && field.isStatic ? binding : null;
  }

  _Binding? _lookup(String name, AstNode use) {
    for (AstNode? owner = use.parent; owner != null; owner = owner.parent) {
      final binding = _scopes[owner]?[name];
      if (binding != null) return binding;
      // An inherited member may hide a global with the same name. Without a
      // resolved class hierarchy, do not fall through to that global.
      if ((owner is ClassDeclaration &&
              (owner.extendsClause != null || owner.withClause != null)) ||
          (owner is! ClassDeclaration && _isType(owner))) {
        return _Binding(null, false);
      }
    }
    return null;
  }

  void _bind(AstNode owner, String name, [VariableDeclaration? declaration]) {
    final scope = _scopes.putIfAbsent(owner, () => {});
    // Duplicate declarations are invalid Dart; do not guess which one is used.
    scope[name] = scope.containsKey(name)
        ? _Binding(null, true)
        : _Binding(declaration, owner is! CompilationUnit && !_isType(owner));
  }
}

final class _Binding {
  _Binding(this.declaration, this.local);
  final VariableDeclaration? declaration;
  final bool local;
}

bool _isType(AstNode node) =>
    node is ClassDeclaration ||
    node is MixinDeclaration ||
    node is EnumDeclaration ||
    node is ExtensionDeclaration ||
    node is ExtensionTypeDeclaration;

AstNode _owner(AstNode node, {bool pattern = false}) {
  for (AstNode? current = node; current != null; current = current.parent) {
    if (current is Block ||
        current is CompilationUnit ||
        _isType(current) ||
        current is FunctionExpression ||
        current is MethodDeclaration ||
        current is ConstructorDeclaration ||
        current is ForStatement ||
        current is ForElement ||
        current is CatchClause ||
        current is SwitchMember ||
        current is SwitchExpressionCase ||
        (pattern && (current is IfStatement || current is IfElement))) {
      return current;
    }
  }
  throw StateError('Declaration has no enclosing Dart scope.');
}

final class _Declarations extends RecursiveAstVisitor<void> {
  _Declarations(this.references);
  final StringReferences references;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    references._bind(_owner(node.parent!), node.name.lexeme, node);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    final parent = node.parent;
    if (parent is FunctionExpression ||
        parent is MethodDeclaration ||
        parent is ConstructorDeclaration ||
        parent is PrimaryConstructorDeclaration) {
      for (final parameter in node.parameters) {
        final name = parameter.name;
        if (name != null) {
          final scope = parent is PrimaryConstructorDeclaration
              ? _owner(parent)
              : parent!;
          references._bind(scope, name.lexeme);
        }
      }
    }
    super.visitFormalParameterList(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    references._bind(_owner(node.parent!), node.name.lexeme);
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    references._bind(_owner(node.parent!, pattern: true), node.name.lexeme);
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    final exception = node.exceptionParameter;
    final stackTrace = node.stackTraceParameter;
    if (exception != null) references._bind(node, exception.name.lexeme);
    if (stackTrace != null) references._bind(node, stackTrace.name.lexeme);
    super.visitCatchClause(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    references._bind(_owner(node.parent!), node.name.lexeme);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    references._bind(_owner(node.parent!), node.name.lexeme);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    references._classes[node.namePart.typeName.lexeme] = node;
    super.visitClassDeclaration(node);
  }

  @override
  void visitTypeParameterList(TypeParameterList node) {
    final parent = node.parent;
    // Function-type parameters belong to a type, not the surrounding method.
    if (parent is ClassNamePart ||
        parent is FunctionExpression ||
        parent is MethodDeclaration ||
        parent is MixinDeclaration) {
      for (final parameter in node.typeParameters) {
        references._bind(_owner(parent!), parameter.name.lexeme);
      }
    }
    super.visitTypeParameterList(node);
  }
}
