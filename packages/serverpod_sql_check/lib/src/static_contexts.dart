import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'dart_sources.dart';
import 'static_demand.dart';
import 'static_evaluator.dart';
import 'static_objects.dart';
import 'static_value.dart';

/// Supplies readable arguments at closed, private or lexical call sites.
///
/// Public entry points keep unknown arguments. A tear-off, unresolved use,
/// competing private selector, library part, or cycle prevents narrowing the
/// entry point to the calls visible in this source file.
final class StaticContexts {
  StaticContexts(this.unit, this.evaluator, this.objects) {
    unit.unit.accept(_index);
  }
  final DartUnit unit;
  final StaticEvaluator evaluator;
  final SourceObjects objects;
  final _ContextIndex _index = _ContextIndex();
  final _entries = <AstNode, List<StaticFrame>>{};

  List<StaticFrame> framesAt(
    AstNode use, {
    Set<AstNode>? needed,
    Set<AstNode>? keysOnly,
  }) {
    final owner = _callable(use);
    final entries = owner == null ? [StaticFrame(unit)] : _entry(owner, {});
    return [
      for (final entry in entries)
        ...evaluator.framesAt(
          use,
          unit,
          initial: entry.copy(),
          needed: needed,
          keysOnly: keysOnly,
        ),
    ];
  }

  List<StaticFrame> _entry(AstNode owner, Set<AstNode> active) {
    final cached = _entries[owner];
    if (cached != null) return cached.map((frame) => frame.copy()).toList();
    if (active.length >= StaticEvaluator.limit || !active.add(owner)) {
      return _base(owner);
    }
    try {
      final calls = _closedCalls(owner);
      if (calls == null || calls.isEmpty) return _base(owner);
      final result = <StaticFrame>[];
      for (final call in calls) {
        final demand = StaticDemand(call, null, unit);
        final caller = _callable(call);
        if (caller != null && active.contains(caller)) return _base(owner);
        final entry = caller == null
            ? [StaticFrame(unit)]
            : _entry(caller, active);
        for (final frame in entry) {
          final reached = evaluator.framesAt(
            call,
            unit,
            initial: frame.copy(),
            needed: demand.needed,
          );
          // An unsupported surrounding flow is not evidence that this call
          // cannot happen. Retain an unknown argument path in that case.
          if (reached.isEmpty) return _base(owner);
          for (final atCall in reached) {
            final bound = _bind(owner, call.argumentList, atCall);
            if (bound == null) return _base(owner);
            result.addAll(bound);
            if (result.length > StaticEvaluator.limit) return _base(owner);
          }
        }
      }
      if (result.isEmpty) return _base(owner);
      _entries[owner] = result.map((frame) => frame.copy()).toList();
      return result;
    } finally {
      active.remove(owner);
    }
  }

  List<StaticFrame> _base(AstNode owner, {StaticFrame? initial}) {
    final frame = initial ?? StaticFrame(unit);
    final type = owner.parent?.parent;
    if (owner is MethodDeclaration &&
        !owner.isStatic &&
        type is ClassDeclaration) {
      final current = frame.receiver;
      if (current != null && identical(current.type.node, type)) return [frame];
      final values = objects.defaultReceiver(
        unit,
        type,
        evaluator,
        frame: frame,
      );
      return [
        for (final value in values)
          if (value.value is ObjectValue)
            _receiverFrame(value.frame, value.value as ObjectValue),
      ];
    }
    frame.receiver = null;
    return [frame];
  }

  StaticFrame _receiverFrame(StaticFrame frame, ObjectValue receiver) {
    frame.receiver = receiver;
    final type = receiver.type.node;
    if (type is ClassDeclaration) {
      for (final field in type.body.members.whereType<FieldDeclaration>()) {
        if (field.isStatic) continue;
        for (final variable in field.fields.variables) {
          frame.env[variable] =
              receiver.fields[variable.name.lexeme] ??
              UnknownValue('unknown receiver field');
        }
      }
    }
    return frame;
  }

  List<MethodInvocation>? _closedCalls(AstNode owner) {
    if (!unit.readable ||
        unit.unit.directives.any(
          (directive) =>
              directive is PartDirective || directive is PartOfDirective,
        )) {
      return null;
    }
    final String name;
    final bool local;
    if (owner is FunctionDeclaration && owner.propertyKeyword == null) {
      name = owner.name.lexeme;
      local = owner.parent is FunctionDeclarationStatement;
      if (!local && !name.startsWith('_')) return null;
    } else if (owner is MethodDeclaration && owner.propertyKeyword == null) {
      name = owner.name.lexeme;
      local = false;
      if (!name.startsWith('_') ||
          _index.methods.where((node) => node.name.lexeme == name).length !=
              1) {
        return null;
      }
    } else {
      return null;
    }
    final result = <MethodInvocation>[];
    for (final call in _index.calls) {
      if (call.methodName.name != name) continue;
      final target = unit.sources.resolve(call, unit)?.node;
      if (identical(target, owner)) {
        result.add(call);
      } else if (!local && target == null) {
        return null;
      }
    }
    for (final identifier in _index.identifiers) {
      if (identifier.name != name) continue;
      final parent = identifier.parent;
      if (parent is MethodInvocation &&
          identical(parent.methodName, identifier)) {
        continue;
      }
      final target = unit.sources.resolve(identifier, unit)?.node;
      if (identical(target, owner) || (!local && target == null)) return null;
    }
    return result;
  }

  List<StaticFrame>? _bind(
    AstNode owner,
    ArgumentList arguments,
    StaticFrame caller,
  ) {
    final parameters = owner is FunctionDeclaration
        ? owner.functionExpression.parameters
        : (owner as MethodDeclaration).parameters;
    final positional = <Expression>[];
    final named = <String, Expression>{};
    for (final argument in arguments.arguments) {
      if (argument is NamedArgument) {
        if (named.containsKey(argument.name.lexeme)) return null;
        named[argument.name.lexeme] = argument.argumentExpression;
      } else {
        positional.add(argument.argumentExpression);
      }
    }
    var frames = [caller];
    final anchors = <FormalParameter, Object>{};
    var position = 0;
    for (final parameter in parameters?.parameters ?? <FormalParameter>[]) {
      final supplied = parameter.isNamed
          ? named.remove(parameter.name?.lexeme)
          : position < positional.length
          ? positional[position++]
          : null;
      if (supplied == null && parameter.isRequired) return null;
      final expression = supplied ?? parameter.defaultClause?.value;
      final anchor = Object();
      anchors[parameter] = anchor;
      final next = <StaticFrame>[];
      for (final frame in frames) {
        if (expression == null) {
          frame.env[anchor] = ScalarValue(null);
          next.add(frame);
        } else {
          for (final value in evaluator.evaluate(expression, frame)) {
            value.frame.env[anchor] = value.value;
            next.add(value.frame);
          }
        }
      }
      if (next.length > StaticEvaluator.limit) return null;
      frames = next;
    }
    if (position != positional.length || named.isNotEmpty) return null;
    return [
      for (final frame in frames)
        ..._base(owner, initial: frame).map((entered) {
          for (final binding in anchors.entries) {
            entered.env[binding.key] =
                entered.env.remove(binding.value) ??
                UnknownValue('unknown call argument');
            entered.invalidated.remove(binding.key);
          }
          return entered;
        }),
    ];
  }

  AstNode? _callable(AstNode node) {
    for (AstNode? owner = node.parent; owner != null; owner = owner.parent) {
      if (owner is MethodDeclaration) return owner;
      if (owner is FunctionExpression) {
        return owner.parent is FunctionDeclaration ? owner.parent : null;
      }
      if (owner is ConstructorDeclaration) return null;
    }
    return null;
  }
}

final class _ContextIndex extends RecursiveAstVisitor<void> {
  final calls = <MethodInvocation>[];
  final identifiers = <SimpleIdentifier>[];
  final methods = <MethodDeclaration>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    calls.add(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    identifiers.add(node);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    methods.add(node);
    super.visitMethodDeclaration(node);
  }
}
