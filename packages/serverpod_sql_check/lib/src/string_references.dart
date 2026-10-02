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
  final _targets = Map<Expression, AstNode?>.identity();

  /// Type declarations share a namespace with variables and parameters.
  /// A shadowed or ambiguous type cannot safely identify a constructor.
  AstNode? typeFor(String name, AstNode use) {
    final node = _lookup(name, use)?.declaration;
    return node is ClassDeclaration || node is EnumDeclaration ? node : null;
  }

  /// Returns a safely readable initializer's declaration, or null if unknown.
  ///
  /// Local declarations must precede their use. Imported values, getters,
  /// mutable variables, late values, and runtime parameters are not resolved.
  VariableDeclaration? declarationFor(Expression reference) {
    final declaration = targetFor(reference);
    if (declaration is! VariableDeclaration) return null;
    final list = declaration.parent;
    if (list is! VariableDeclarationList ||
        (!list.isConst && !list.isFinal) ||
        list.isLate ||
        declaration.initializer == null) {
      return null;
    }
    return declaration;
  }

  /// Returns the lexical target, including helper functions and parameters.
  AstNode? targetFor(Expression reference) {
    if (_targets.containsKey(reference)) return _targets[reference];
    return _targets[reference] = _targetFor(reference);
  }

  AstNode? _targetFor(Expression reference) {
    _Binding? binding;
    if (reference is SimpleIdentifier) {
      binding = _lookup(reference.name, reference);
    } else if (reference is PrefixedIdentifier) {
      binding = _classMember(
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
      binding = _classMember(
        (reference.target as SimpleIdentifier).name,
        reference.propertyName.name,
        reference,
      );
    } else if (reference is MethodInvocation) {
      final target = reference.target;
      if (target == null) {
        binding = _lookup(reference.methodName.name, reference);
      } else if (target is ThisExpression) {
        for (
          AstNode? node = reference.parent;
          node != null;
          node = node.parent
        ) {
          if (node is ClassDeclaration) {
            binding = _scopes[node]?[reference.methodName.name];
            break;
          }
        }
      } else if (target is SimpleIdentifier) {
        binding = _classMember(
          target.name,
          reference.methodName.name,
          reference,
        );
      }
    }
    final declaration = binding?.declaration;
    if (declaration == null) return null;
    if (binding!.local &&
        declaration is VariableDeclaration &&
        reference.offset < declaration.offset) {
      return null;
    }
    return declaration;
  }

  /// A lexical binding, including an unsupported one, hides imported names.
  bool shadowsName(String name, AstNode use) =>
      _lookup(name, use) != null || _classes.containsKey(name);

  /// Checks actual declarations without assuming an unknown inherited member.
  bool hasDirectBinding(String name, AstNode use) {
    if (_classes.containsKey(name)) return true;
    for (AstNode? owner = use.parent; owner != null; owner = owner.parent) {
      if (_scopes[owner]?.containsKey(name) ?? false) return true;
    }
    return false;
  }

  bool declaresMember(AstNode owner, String name) =>
      _scopes[owner]?.containsKey(name) ?? false;

  _Binding? _classMember(String className, String fieldName, AstNode use) {
    // A local variable or parameter called ClassName shadows the actual class.
    final type = _lookup(className, use);
    final owner = type?.declaration;
    if (owner is! ClassDeclaration && owner is! EnumDeclaration) return null;
    if (owner is EnumDeclaration) {
      final constants = owner.body.constants.where(
        (constant) => constant.name.lexeme == fieldName,
      );
      if (constants.length == 1) return _Binding(constants.single, false);
      if (fieldName == 'values') return _Binding(owner, false);
    }
    final binding = _scopes[owner]?[fieldName];
    final method = binding?.declaration;
    if (method is MethodDeclaration && method.isStatic) return binding;
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
              (owner.extendsClause != null ||
                  owner.withClause != null ||
                  owner.implementsClause != null)) ||
          (owner is! ClassDeclaration && _isType(owner))) {
        return _Binding(null, false);
      }
    }
    return null;
  }

  void _bind(AstNode owner, String name, [AstNode? declaration]) {
    final scope = _scopes.putIfAbsent(owner, () => {});
    final previous = scope[name]?.declaration;
    // A getter/setter pair is one property. Reads select its getter; repeated
    // getters or any other duplicate declaration remain ambiguous.
    if (_getter(previous) && _setter(declaration)) return;
    if (_setter(previous) && _getter(declaration)) {
      scope[name] = _Binding(
        declaration,
        owner is! CompilationUnit && !_isType(owner),
      );
      return;
    }
    // Duplicate declarations are invalid Dart; do not guess which one is used.
    scope[name] = scope.containsKey(name)
        ? _Binding(null, true)
        : _Binding(declaration, owner is! CompilationUnit && !_isType(owner));
  }
}

bool _getter(AstNode? node) =>
    node is FunctionDeclaration && node.isGetter ||
    node is MethodDeclaration && node.isGetter;
bool _setter(AstNode? node) =>
    node is FunctionDeclaration && node.isSetter ||
    node is MethodDeclaration && node.isSetter;

final class _Binding {
  _Binding(this.declaration, this.local);
  final AstNode? declaration;
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
          references._bind(scope, name.lexeme, parameter);
        }
      }
    }
    super.visitFormalParameterList(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    references._bind(_owner(node.parent!), node.name.lexeme, node);
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
    references._bind(_owner(node.parent!), node.name.lexeme, node);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    references._bind(_owner(node.parent!), node.name.lexeme, node);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    references._classes[node.namePart.typeName.lexeme] = node;
    references._bind(_owner(node.parent!), node.namePart.typeName.lexeme, node);
    super.visitClassDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    references._bind(_owner(node.parent!), node.namePart.typeName.lexeme, node);
    for (final constant in node.body.constants) {
      references._bind(node, constant.name.lexeme, constant);
    }
    super.visitEnumDeclaration(node);
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
