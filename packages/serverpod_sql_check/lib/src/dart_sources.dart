import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import 'string_references.dart';

/// Source content is retained so diagnostics can point across file boundaries.
class SourceFile {
  SourceFile(this.path, this.content);

  final String path;
  final String content;
}

final class DartUnit extends SourceFile {
  DartUnit(super.path, super.content, this.packages, this.sources) {
    final parsed = parseString(content: content, throwIfDiagnostics: false);
    unit = parsed.unit;
    readable = parsed.errors.isEmpty;
    final finalParameters = _FinalParameters();
    unit.accept(finalParameters);
    // Older dependency sources sometimes retain `final` formal modifiers.
    // The analyzer records those parameters and declaration boundaries but
    // reports the redundant modifier. Their bodies remain unreadable; the
    // complete namespace can still prove that an unrelated name is absent.
    namespaceReadable = parsed.errors.every(
      (error) =>
          error.diagnosticCode.lowerCaseName == 'extraneous_modifier' &&
          finalParameters.offsets.contains(error.offset),
    );
    references = StringReferences(unit);
    for (final declaration in unit.declarations) {
      if (declaration is TopLevelVariableDeclaration) {
        for (final variable in declaration.variables.variables) {
          _declare(variable.name.lexeme, variable);
        }
      } else if (declaration is FunctionDeclaration) {
        _declare(declaration.name.lexeme, declaration);
      } else if (declaration is ClassDeclaration) {
        _declare(declaration.namePart.typeName.lexeme, declaration);
      } else if (declaration is MixinDeclaration) {
        _declare(declaration.name.lexeme, declaration);
      } else if (declaration is EnumDeclaration) {
        _declare(declaration.namePart.typeName.lexeme, declaration);
      }
    }
  }

  final DartSources sources;
  final _Packages packages;
  late final CompilationUnit unit;
  late final StringReferences references;
  late final bool readable;
  late final bool namespaceReadable;
  final declarations = <String, AstNode?>{};

  void _declare(String name, AstNode node) {
    final previous = declarations[name];
    if (previous is FunctionDeclaration &&
        previous.isGetter &&
        node is FunctionDeclaration &&
        node.isSetter) {
      return;
    }
    if (previous is FunctionDeclaration &&
        previous.isSetter &&
        node is FunctionDeclaration &&
        node.isGetter) {
      declarations[name] = node;
      return;
    }
    declarations[name] = declarations.containsKey(name) ? null : node;
  }
}

final class DartDeclaration {
  DartDeclaration(this.unit, this.node);

  final DartUnit unit;
  final AstNode node;
}

typedef _Namespace = ({List<DartDeclaration> declarations, bool uncertain});

/// A cached source graph using Dart's package configuration and namespaces.
///
/// No application code is executed, and no runtime Dart SDK is required. An
/// ambiguous name or configurable import/export is left unresolved.
final class DartSources {
  final _units = <(String, String?), DartUnit>{};
  final _packageConfigs = <String?, _Packages>{};
  final _exports = <(DartUnit, String), _Namespace>{};
  final _resolutions =
      Map<DartUnit, Map<Expression, DartDeclaration?>>.identity();
  final _typeResolutions =
      Map<DartUnit, Map<AstNode, Map<String, DartDeclaration?>>>.identity();
  final _coreTypes = Map<DartUnit, Map<AstNode, Map<String, bool>>>.identity();

  Iterable<DartUnit> get units => _units.values.toList(growable: false);

  /// Verifies that a recognized core constructor is not shadowed or ambiguous.
  bool coreTypeAvailable(String name, AstNode use, DartUnit unit) {
    final uses = _coreTypes.putIfAbsent(unit, () => Map.identity());
    final cache = uses.putIfAbsent(use, () => {});
    return cache.putIfAbsent(name, () => _coreTypeAvailable(name, use, unit));
  }

  bool _coreTypeAvailable(String name, AstNode use, DartUnit unit) {
    if (!unit.readable ||
        unit.references.shadowsName(name, use) &&
            (unit.references.hasDirectBinding(name, use) ||
                !_inheritanceAllowsImport(unit, use, name))) {
      return false;
    }
    final imports = unit.unit.directives.whereType<ImportDirective>();
    final explicitCore = imports.where(
      (directive) => directive.uri.stringValue == 'dart:core',
    );
    if (explicitCore.isNotEmpty &&
        !explicitCore.any(
          (directive) =>
              directive.prefix == null && _visible(directive.combinators, name),
        )) {
      return false;
    }
    for (final directive in imports) {
      if (directive.prefix != null || !_visible(directive.combinators, name)) {
        continue;
      }
      if (directive.configurations.isNotEmpty) return false;
      final uri = directive.uri.stringValue;
      if (uri?.startsWith('dart:') ?? false) continue;
      final imported = _import(unit, uri);
      if (imported == null) return false;
      final namespace = _exports.putIfAbsent((
        imported,
        name,
      ), () => _exported(imported, name, {}));
      if (namespace.uncertain || namespace.declarations.isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  DartUnit unitFor(String path, {String? content}) {
    final normalized = _normalize(path);
    final packages = _packagesFor(normalized);
    return _load(normalized, packages, content: content);
  }

  DartUnit _load(String path, _Packages packages, {String? content}) =>
      _units.putIfAbsent(
        (path, packages.configPath),
        () => DartUnit(
          path,
          content ?? File(path).readAsStringSync(),
          packages,
          this,
        ),
      );

  DartDeclaration? resolve(Expression expression, DartUnit unit) {
    // Resolution depends on the parsed namespace, never on evaluator state.
    // Remember misses as well: dynamic member expressions recur on each path.
    final cache = _resolutions.putIfAbsent(unit, () => Map.identity());
    if (cache.containsKey(expression)) return cache[expression];
    return cache[expression] = _resolve(expression, unit);
  }

  DartDeclaration? _resolve(Expression expression, DartUnit unit) {
    if (!unit.readable) return null;
    final local = unit.references.targetFor(expression);
    if (local != null) return DartDeclaration(unit, local);
    final names = _names(expression);
    if (names == null || names.isEmpty) {
      return null;
    }
    if (unit.references.shadowsName(names.first, expression) &&
        (unit.references.hasDirectBinding(names.first, expression) ||
            !_inheritanceAllowsImport(unit, expression, names.first))) {
      return null;
    }
    return _imported(unit, names);
  }

  /// Resolves a type name using the same lexical and import rules as values.
  ///
  /// Constructor/type nodes are not expressions in a parsed, unresolved AST.
  /// Keeping this lookup here avoids a separate, less strict import resolver.
  DartDeclaration? resolveTypeNames(
    List<String> names,
    AstNode use,
    DartUnit unit,
  ) {
    final uses = _typeResolutions.putIfAbsent(unit, () => Map.identity());
    final cache = uses.putIfAbsent(use, () => {});
    // Each segment is a Dart identifier, so the separator cannot occur in a
    // segment. Names remain distinct without retaining caller-owned lists.
    final path = names.join('.');
    if (cache.containsKey(path)) return cache[path];
    return cache[path] = _resolveTypeNames(names, use, unit);
  }

  DartDeclaration? _resolveTypeNames(
    List<String> names,
    AstNode use,
    DartUnit unit,
  ) {
    if (!unit.readable || names.isEmpty) return null;
    if (names.length == 1) {
      final local = unit.references.typeFor(names.single, use);
      if (local != null) return DartDeclaration(unit, local);
    }
    if (unit.references.shadowsName(names.first, use) &&
        (unit.references.hasDirectBinding(names.first, use) ||
            !_inheritanceAllowsImport(unit, use, names.first))) {
      return null;
    }
    final declaration = _imported(unit, names);
    return declaration?.node is ClassDeclaration ||
            declaration?.node is EnumDeclaration
        ? declaration
        : null;
  }

  DartDeclaration? resolveNamedType(
    NamedType type,
    AstNode use,
    DartUnit unit,
  ) => resolveTypeNames(
    [
      if (type.importPrefix != null) type.importPrefix!.name.lexeme,
      type.name.lexeme,
    ],
    use,
    unit,
  );

  DartDeclaration? _imported(DartUnit unit, List<String> names) {
    final matches = <AstNode, DartDeclaration>{};
    final imports = unit.unit.directives.whereType<ImportDirective>();
    final prefixed = imports.any(
      (directive) => directive.prefix?.name == names.first,
    );
    if (prefixed && names.length < 2) return null;
    final symbol = prefixed ? names[1] : names.first;
    final members = names.skip(prefixed ? 2 : 1).toList();
    var uncertain = false;
    for (final directive in imports) {
      final prefix = directive.prefix?.name;
      if ((prefixed ? prefix != names.first : prefix != null) ||
          !_visible(directive.combinators, symbol)) {
        continue;
      }
      if (directive.configurations.isNotEmpty) {
        uncertain = true;
        continue;
      }
      final imported = _import(unit, directive.uri.stringValue);
      if (imported == null) {
        if (!(directive.uri.stringValue?.startsWith('dart:') ?? false)) {
          uncertain = true;
        }
        continue;
      }
      final namespace = _exports.putIfAbsent((
        imported,
        symbol,
      ), () => _exported(imported, symbol, {}));
      uncertain |= namespace.uncertain;
      for (final declaration in namespace.declarations) {
        matches[declaration.node] = declaration;
      }
    }
    return !uncertain && matches.length == 1
        ? _member(matches.values.single, members)
        : null;
  }

  bool _inheritanceAllowsImport(DartUnit unit, AstNode use, String name) {
    for (AstNode? owner = use.parent; owner != null; owner = owner.parent) {
      if (owner is ClassDeclaration || owner is MixinDeclaration) {
        if (_typeMayDefine(DartDeclaration(unit, owner), name, {})) {
          return false;
        }
      } else if (owner is EnumDeclaration ||
          owner is ExtensionDeclaration ||
          owner is ExtensionTypeDeclaration) {
        return false;
      }
    }
    return true;
  }

  bool _typeMayDefine(
    DartDeclaration declaration,
    String name,
    Set<AstNode> active,
  ) {
    final node = declaration.node;
    final unit = declaration.unit;
    if (!unit.readable || !active.add(node)) return true;
    try {
      if (unit.references.declaresMember(node, name)) return true;
      final bases = <NamedType>[];
      if (node is ClassDeclaration) {
        final parent = node.extendsClause?.superclass;
        if (parent != null) bases.add(parent);
        bases.addAll(node.withClause?.mixinTypes ?? <NamedType>[]);
        bases.addAll(node.implementsClause?.interfaces ?? <NamedType>[]);
      } else if (node is MixinDeclaration) {
        bases.addAll(node.onClause?.superclassConstraints ?? <NamedType>[]);
      } else {
        return true;
      }
      for (final base in bases) {
        final prefix = base.importPrefix?.name.lexeme;
        final names = [if (prefix != null) prefix, base.name.lexeme];
        final local = prefix == null ? unit.declarations[names.single] : null;
        final target = local != null
            ? DartDeclaration(unit, local)
            : _imported(unit, names);
        if (target == null || _typeMayDefine(target, name, active)) return true;
      }
      // Every class also inherits Object's public instance members.
      return const {
        'hashCode',
        'runtimeType',
        'toString',
        'noSuchMethod',
      }.contains(name);
    } finally {
      active.remove(node);
    }
  }

  _Namespace _exported(DartUnit unit, String name, Set<DartUnit> active) {
    if (name.startsWith('_')) return (declarations: [], uncertain: false);
    if (!unit.namespaceReadable) return (declarations: [], uncertain: true);
    // Keep visits for the whole root traversal: the first path contributes the
    // library's complete namespace, and export diamonds need not rewalk it.
    if (!active.add(unit)) return (declarations: [], uncertain: false);
    if (unit.declarations.containsKey(name)) {
      final node = unit.declarations[name];
      return (
        declarations: node == null ? [] : [DartDeclaration(unit, node)],
        uncertain: node == null,
      );
    }
    final matches = <AstNode, DartDeclaration>{};
    var uncertain = false;
    for (final directive in unit.unit.directives.whereType<ExportDirective>()) {
      if (!_visible(directive.combinators, name)) continue;
      if (directive.configurations.isNotEmpty) {
        uncertain = true;
        continue;
      }
      final exported = _import(unit, directive.uri.stringValue);
      if (exported == null) {
        uncertain = true;
        continue;
      }
      final namespace = _exported(exported, name, active);
      uncertain |= namespace.uncertain;
      for (final declaration in namespace.declarations) {
        matches[declaration.node] = declaration;
      }
    }
    return (declarations: matches.values.toList(), uncertain: uncertain);
  }

  DartDeclaration? _member(DartDeclaration declaration, List<String> names) {
    if (names.isEmpty) return declaration;
    final node = declaration.node;
    if (names.length != 1 || names.single.startsWith('_')) {
      return null;
    }
    if (node is EnumDeclaration) {
      final constant = node.body.constants.where(
        (constant) => constant.name.lexeme == names.single,
      );
      if (constant.length == 1) {
        return DartDeclaration(declaration.unit, constant.single);
      }
      if (names.single == 'values') return declaration;
    }
    final members = switch (node) {
      ClassDeclaration() => node.body.members,
      EnumDeclaration() => node.body.members,
      _ => null,
    };
    if (members == null) return null;
    final matches = <AstNode>[];
    for (final member in members) {
      if (member is FieldDeclaration && member.isStatic) {
        matches.addAll(
          member.fields.variables.where((v) => v.name.lexeme == names.single),
        );
      } else if (member is MethodDeclaration &&
          member.isStatic &&
          !member.isSetter &&
          member.name.lexeme == names.single) {
        matches.add(member);
      }
    }
    return matches.length == 1
        ? DartDeclaration(declaration.unit, matches.single)
        : null;
  }

  DartUnit? _import(DartUnit from, String? value) {
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    Uri? resolved;
    if (uri.scheme == 'package') {
      final segments = uri.pathSegments;
      if (segments.isEmpty) return null;
      final base = from.packages.libraries[segments.first];
      resolved = base?.resolveUri(Uri(path: segments.skip(1).join('/')));
    } else if (uri.scheme.isEmpty || uri.scheme == 'file') {
      resolved = Uri.file(from.path).resolveUri(uri);
    }
    if (resolved == null || resolved.scheme != 'file') return null;
    try {
      final path = _normalize(resolved.toFilePath());
      if (!File(path).existsSync()) return null;
      return _load(path, from.packages);
    } on FileSystemException {
      return null;
    }
  }

  _Packages _packagesFor(String path) {
    String? configPath;
    for (var folder = Directory(p.dirname(path)); ; folder = folder.parent) {
      final file = File(
        p.join(folder.path, '.dart_tool', 'package_config.json'),
      );
      if (file.existsSync()) {
        configPath = file.path;
        break;
      }
      if (folder.parent.path == folder.path) break;
    }
    return _packageConfigs.putIfAbsent(configPath, () => _Packages(configPath));
  }
}

final class _Packages {
  _Packages(this.configPath) {
    if (configPath == null) return;
    final config = jsonDecode(File(configPath!).readAsStringSync());
    if (config is! Map ||
        config['configVersion'] != 2 ||
        config['packages'] is! List) {
      throw FormatException('Invalid Dart package configuration: $configPath');
    }
    final base = Uri.file(configPath!);
    for (final package in config['packages'] as List) {
      if (package is! Map ||
          package['name'] is! String ||
          package['rootUri'] is! String) {
        continue;
      }
      final root = _directoryUri(base.resolve(package['rootUri'] as String));
      final library = root.resolve(package['packageUri'] as String? ?? '');
      libraries[package['name'] as String] = _directoryUri(library);
    }
  }

  final String? configPath;
  final libraries = <String, Uri>{};
}

String _normalize(String path) => p.normalize(File(path).absolute.path);

Uri _directoryUri(Uri uri) =>
    uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');

List<String>? _names(Expression expression) => switch (expression) {
  SimpleIdentifier() => [expression.name],
  PrefixedIdentifier() => [expression.prefix.name, expression.identifier.name],
  PropertyAccess() => switch (expression.target == null
      ? null
      : _names(expression.target!)) {
    final List<String> names => [...names, expression.propertyName.name],
    _ => null,
  },
  MethodInvocation() =>
    expression.target == null
        ? [expression.methodName.name]
        : switch (_names(expression.target!)) {
            final List<String> names => [...names, expression.methodName.name],
            _ => null,
          },
  _ => null,
};

bool _visible(NodeList<Combinator> combinators, String name) =>
    !name.startsWith('_') &&
    combinators.every(
      (combinator) => switch (combinator) {
        ShowCombinator() => combinator.shownNames.any((n) => n.name == name),
        HideCombinator() => !combinator.hiddenNames.any((n) => n.name == name),
      },
    );

final class _FinalParameters extends RecursiveAstVisitor<void> {
  final offsets = <int>{};

  @override
  void visitFormalParameterList(FormalParameterList node) {
    for (final parameter in node.parameters) {
      final keyword = parameter.finalKeyword;
      if (keyword != null) offsets.add(keyword.offset);
    }
    super.visitFormalParameterList(node);
  }
}
