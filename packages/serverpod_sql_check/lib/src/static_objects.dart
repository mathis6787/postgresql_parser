import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';

import 'dart_sources.dart';
import 'static_value.dart';

/// Reads records, enum constants, and plain generative object initializers.
///
/// Exact construction and safe private members can supply readable values.
/// Runtime receivers, inherited members, late fields, and unknown writes stay
/// unknown. Factory bodies use the same bounded source evaluator as helpers.
final class SourceObjects implements StaticObjects {
  /// Builds a partial receiver for a declaration without guessing constructor
  /// arguments. Only immutable declaration initializers whose getters cannot
  /// be overridden are readable.
  List<StaticOutcome> defaultReceiver(
    DartUnit unit,
    ClassDeclaration owner,
    StaticRuntime runtime, {
    StaticFrame? frame,
  }) {
    final caller = frame ?? StaticFrame(unit);
    final type = DartDeclaration(unit, owner);
    final fields = {
      for (final member in owner.body.members.whereType<FieldDeclaration>())
        if (!member.isStatic)
          for (final field in member.fields.variables) field.name.lexeme: field,
    };
    final anchor = Object();
    final present = caller.env.keys.toSet();
    final state = caller.copy();
    state.env[anchor] = RecordValue([
      ObjectValue(type, {
        for (final name in fields.keys)
          name: UnknownValue('Unknown receiver field'),
      }, exact: false),
      RecordValue([
        for (final field in fields.values)
          state.env[field] ?? UnknownValue('Absent receiver binding'),
      ], {}),
      state.receiver ?? UnknownValue('Absent caller receiver'),
    ], {});
    for (final field in fields.values) {
      state.env[field] = UnknownValue('Unknown receiver field');
    }
    var outcomes = [StaticOutcome(state.env[anchor]!, state.withUnit(unit))];
    for (final entry in fields.entries) {
      final field = entry.value;
      final list = field.parent as VariableDeclarationList;
      final next = <StaticOutcome>[];
      for (final prior in outcomes) {
        final context = prior.frame.env[anchor] as RecordValue;
        prior.frame.receiver = context.positional.first as ObjectValue;
        final initializer = field.initializer;
        final values =
            unit.readable &&
                !prior.frame.active.contains(field) &&
                _safeDispatch(type, entry.key) &&
                list.isFinal &&
                !list.isLate &&
                initializer != null &&
                !_constructorWrites(owner, entry.key)
            ? runtime.evaluate(initializer, prior.frame..active.add(field))
            : _unknown(prior.frame, 'Unknown receiver field');
        for (final value in values) {
          value.frame.active.remove(field);
          final current = value.frame.env[anchor] as RecordValue;
          final object = current.positional.first as ObjectValue;
          final immutable = _immutableValue(value.value);
          final updated = ObjectValue(type, {
            ...object.fields,
            entry.key: immutable,
          }, exact: false);
          value.frame.env[anchor] = RecordValue([
            updated,
            current.positional[1],
            current.positional[2],
          ], {});
          value.frame.env[field] = immutable;
          next.add(StaticOutcome(updated, value.frame));
        }
      }
      if (next.length > 32) {
        // An unsupported initializer must not drop a call-site path.
        return [
          StaticOutcome(
            ObjectValue(type, {
              for (final name in fields.keys)
                name: UnknownValue('Receiver variant limit'),
            }, exact: false),
            caller,
          ),
        ];
      }
      outcomes = next;
    }
    return [
      for (final outcome in outcomes)
        _finishReceiver(outcome, anchor, fields, present, caller.unit),
    ];
  }

  @override
  List<StaticOutcome>? evaluate(
    Expression expression,
    StaticFrame frame,
    StaticRuntime runtime,
  ) {
    if (expression is RecordLiteral) {
      final anchor = Object();
      frame.env[anchor] = RecordValue([], {});
      var outcomes = [StaticOutcome(frame.env[anchor]!, frame)];
      for (final field in expression.fields) {
        final next = <StaticOutcome>[];
        for (final prior in outcomes) {
          for (final value in runtime.evaluate(
            field.fieldExpression,
            prior.frame,
          )) {
            final record = value.frame.env[anchor] as RecordValue;
            final positional = [...record.positional];
            final named = {...record.named};
            if (field is RecordLiteralNamedField) {
              if (named.containsKey(field.name.lexeme)) {
                return _unknown(frame, 'Duplicate record field');
              }
              named[field.name.lexeme] = value.value;
            } else {
              positional.add(value.value);
            }
            final recordValue = RecordValue(positional, named);
            value.frame.env[anchor] = recordValue;
            next.add(StaticOutcome(recordValue, value.frame));
          }
        }
        if (next.length > 32) return _unknown(frame, 'Record variant limit');
        outcomes = next;
      }
      return [
        for (final outcome in outcomes)
          StaticOutcome(outcome.frame.env.remove(anchor)!, outcome.frame),
      ];
    }

    if (expression is SimpleIdentifier ||
        expression is PrefixedIdentifier ||
        expression is PropertyAccess) {
      final declaration = frame.unit.sources.resolve(expression, frame.unit);
      final node = declaration?.node;
      if (node is FunctionDeclaration && node.isGetter ||
          node is MethodDeclaration && node.isStatic && node.isGetter) {
        return runtime.invokeCallable(declaration!, _emptyArguments, frame);
      }
      if (node is MethodDeclaration &&
          node.isGetter &&
          !node.isStatic &&
          frame.receiver != null) {
        return property(frame.receiver!, node.name.lexeme, frame, runtime);
      }
      if (node is MethodDeclaration &&
          node.isGetter &&
          !node.isStatic &&
          frame.receiver == null) {
        final owner = node.parent?.parent;
        if (owner is ClassDeclaration &&
            _safeDispatch(
              DartDeclaration(declaration!.unit, owner),
              node.name.lexeme,
            )) {
          return [
            for (final receiver in defaultReceiver(
              declaration.unit,
              owner,
              runtime,
              frame: frame,
            ))
              ...runtime.invokeCallable(
                declaration,
                _emptyArguments,
                receiver.frame,
                receiver: receiver.value as ObjectValue,
              ),
          ];
        }
      }
      if (node is EnumConstantDeclaration) {
        final owner = node.parent?.parent;
        if (owner is! EnumDeclaration) return null;
        return [
          StaticOutcome(
            EnumValue(
              DartDeclaration(declaration!.unit, owner),
              owner.body.constants.indexOf(node),
              node.name.lexeme,
            ),
            frame,
          ),
        ];
      }
      if (node is EnumDeclaration && _names(expression)?.last == 'values') {
        return [
          StaticOutcome(
            ListValue([
              for (var index = 0; index < node.body.constants.length; index++)
                EnumValue(
                  declaration!,
                  index,
                  node.body.constants[index].name.lexeme,
                ),
            ]),
            frame,
          ),
        ];
      }
    }

    if (expression is MethodInvocation &&
        (expression.target == null || expression.target is ThisExpression) &&
        frame.receiver == null) {
      final target = frame.unit.sources.resolve(expression, frame.unit);
      final node = target?.node;
      final owner = node?.parent?.parent;
      if (node is MethodDeclaration &&
          !node.isStatic &&
          owner is ClassDeclaration &&
          _safeDispatch(
            DartDeclaration(target!.unit, owner),
            node.name.lexeme,
          )) {
        return [
          for (final receiver in defaultReceiver(
            target.unit,
            owner,
            runtime,
            frame: frame,
          ))
            ...runtime.invokeCallable(
              target,
              expression.argumentList,
              receiver.frame,
              receiver: receiver.value as ObjectValue,
            ),
        ];
      }
    }

    final List<String>? names;
    final ArgumentList arguments;
    if (expression is InstanceCreationExpression) {
      final constructor = expression.constructorName;
      names = [
        if (constructor.type.importPrefix != null)
          constructor.type.importPrefix!.name.lexeme,
        constructor.type.name.lexeme,
        if (constructor.name != null) constructor.name!.name,
      ];
      arguments = expression.argumentList;
    } else if (expression is MethodInvocation) {
      names = _names(expression);
      arguments = expression.argumentList;
    } else {
      return null;
    }
    if (names == null || names.isEmpty) return null;
    var type = frame.unit.sources.resolveTypeNames(
      names,
      expression,
      frame.unit,
    );
    var constructorName = '';
    if (type == null && names.length > 1) {
      type = frame.unit.sources.resolveTypeNames(
        names.sublist(0, names.length - 1),
        expression,
        frame.unit,
      );
      constructorName = names.last;
    }
    if (type?.node is ClassDeclaration) {
      final declaration = type!.node as ClassDeclaration;
      // Parsed `Type.name()` is also used for static helper methods. Claim it
      // as a constructor only when the class actually declares that selector.
      if (expression is MethodInvocation &&
          constructorName.isNotEmpty &&
          !declaration.body.members.whereType<ConstructorDeclaration>().any(
            (constructor) => constructor.name?.lexeme == constructorName,
          )) {
        return null;
      }
      return _construct(
        type,
        constructorName,
        arguments,
        frame,
        runtime,
        Object(),
      );
    }

    // QueryParameters.named is the existing checker's recognized binding API.
    // A real local declaration takes priority over that syntactic convention.
    if (names.length >= 2 &&
        names[names.length - 2] == 'QueryParameters' &&
        names.last == 'named' &&
        type == null &&
        !frame.unit.references.shadowsName(names.first, expression)) {
      if (arguments.arguments.length != 1 ||
          arguments.arguments.single is NamedArgument) {
        return _unknown(frame, 'Unsupported named parameters constructor');
      }
      return [
        for (final value in runtime.evaluate(
          arguments.arguments.single.argumentExpression,
          frame,
        ))
          StaticOutcome(
            value.value is MapValue
                ? BindingsValue(value.value as MapValue)
                : UnknownValue('Unreadable named parameter map'),
            value.frame,
          ),
      ];
    }
    return null;
  }

  @override
  List<StaticOutcome>? property(
    StaticValue receiver,
    String name,
    StaticFrame frame,
    StaticRuntime runtime,
  ) {
    if (receiver is RecordValue) {
      final named = receiver.named[name];
      if (named != null) return [StaticOutcome(named, frame)];
      final position = name.startsWith(r'$')
          ? int.tryParse(name.substring(1))
          : null;
      return [
        StaticOutcome(
          position != null &&
                  position > 0 &&
                  position <= receiver.positional.length
              ? receiver.positional[position - 1]
              : UnknownValue('Unknown record field'),
          frame,
        ),
      ];
    }
    if (receiver is BindingsValue && name == 'named') {
      return [StaticOutcome(receiver.map, frame)];
    }
    if (receiver is EnumValue) {
      if (name == 'index') {
        return [StaticOutcome(ScalarValue(receiver.index), frame)];
      }
      if (name == 'name' && _instanceMember(receiver.type, name) == null) {
        final node = receiver.type.node as EnumDeclaration;
        return [
          StaticOutcome(
            TextValue(
              StaticText.synthetic(
                receiver.name,
                receiver.type.unit,
                node.offset,
              ),
            ),
            frame,
          ),
        ];
      }
      final constructed = _enumObject(receiver, frame, runtime);
      return [
        for (final outcome in constructed)
          ...property(outcome.value, name, outcome.frame, runtime) ??
              _unknown(outcome.frame, 'Unreadable enum field'),
      ];
    }
    if (receiver is! ObjectValue) return null;
    if (name.startsWith('_') && !identical(receiver.type.unit, frame.unit)) {
      return _unknown(frame, 'Private object field');
    }
    if (!receiver.exact && !_safeDispatch(receiver.type, name)) {
      return _unknown(frame, 'Overridable object field');
    }
    final field = receiver.fields[name];
    if (field != null) return [StaticOutcome(field, frame)];
    final member = _instanceMember(receiver.type, name);
    if (member is MethodDeclaration && member.isGetter) {
      return runtime.invokeCallable(
        DartDeclaration(receiver.type.unit, member),
        _emptyArguments,
        frame,
        receiver: receiver,
      );
    }
    return _unknown(frame, 'Unknown or mutable object field');
  }

  @override
  List<StaticOutcome>? method(
    StaticValue receiver,
    MethodInvocation call,
    StaticFrame frame,
    StaticRuntime runtime,
  ) {
    if (receiver is EnumValue) {
      final member = _instanceMember(receiver.type, call.methodName.name);
      if (member == null &&
          call.methodName.name == 'toString' &&
          call.argumentList.arguments.isEmpty) {
        final node = receiver.type.node as EnumDeclaration;
        return [
          StaticOutcome(
            TextValue(
              StaticText.synthetic(
                '${node.namePart.typeName.lexeme}.${receiver.name}',
                receiver.type.unit,
                node.offset,
              ),
            ),
            frame,
          ),
        ];
      }
      return [
        for (final value in _enumObject(receiver, frame, runtime))
          ...method(value.value, call, value.frame, runtime) ??
              _unknown(value.frame, 'Unreadable enum method'),
      ];
    }
    if (receiver is! ObjectValue) return null;
    final name = call.methodName.name;
    if (name.startsWith('_') && !identical(receiver.type.unit, frame.unit)) {
      return _unknown(frame, 'Private object method');
    }
    if (!receiver.exact && !_safeDispatch(receiver.type, name)) {
      return _unknown(frame, 'Overridable object method');
    }
    final member = _instanceMember(receiver.type, name);
    if (member is! MethodDeclaration || member.propertyKeyword != null) {
      return _unknown(frame, 'Unknown object method');
    }
    return runtime.invokeCallable(
      DartDeclaration(receiver.type.unit, member),
      call.argumentList,
      frame,
      receiver: receiver,
    );
  }

  List<StaticOutcome> _enumObject(
    EnumValue value,
    StaticFrame frame,
    StaticRuntime runtime,
  ) {
    final declaration = value.type.node as EnumDeclaration;
    if (value.index < 0 || value.index >= declaration.body.constants.length) {
      return _unknown(frame, 'Invalid enum index');
    }
    final constant = declaration.body.constants[value.index];
    final arguments = constant.arguments;
    return _construct(
          value.type,
          arguments?.constructorSelector?.name.name ?? '',
          arguments?.argumentList,
          frame.withUnit(value.type.unit),
          runtime,
          Object(),
        )
        .map(
          (result) =>
              StaticOutcome(result.value, result.frame.withUnit(frame.unit)),
        )
        .toList();
  }

  List<StaticOutcome> _construct(
    DartDeclaration type,
    String constructorName,
    ArgumentList? arguments,
    StaticFrame caller,
    StaticRuntime runtime,
    Object anchor, {
    DartUnit? accessUnit,
  }) {
    final owner = type.node;
    final NodeList<ClassMember> members;
    if (owner is ClassDeclaration) {
      members = owner.body.members;
    } else if (owner is EnumDeclaration) {
      if (owner.withClause != null || owner.implementsClause != null) {
        return _unknown(caller, 'Inherited enum initialization');
      }
      members = owner.body.members;
    } else {
      return _unknown(caller, 'Unknown constructor type');
    }
    if (type.unit.unit.directives.any(
          (directive) =>
              directive is PartDirective || directive is PartOfDirective,
        ) ||
        (constructorName.startsWith('_') &&
            !identical(type.unit, accessUnit ?? caller.unit))) {
      return _unknown(caller, 'Unavailable constructor library');
    }
    final constructors = members.whereType<ConstructorDeclaration>().toList();
    final matches = constructors
        .where(
          (constructor) => (constructor.name?.lexeme ?? '') == constructorName,
        )
        .toList();
    if (matches.length > 1 ||
        (matches.isEmpty &&
            (constructorName.isNotEmpty || constructors.isNotEmpty))) {
      return _unknown(caller, 'Unknown constructor');
    }
    final constructor = matches.firstOrNull;
    if (constructor != null && constructor.factoryKeyword != null) {
      if (constructor.externalKeyword != null ||
          caller.active.contains(constructor) ||
          !type.unit.readable) {
        return _unknown(caller, 'Unreadable factory constructor');
      }
      final redirect = constructor.redirectedConstructor;
      if (redirect != null) {
        var target = type.unit.sources.resolveNamedType(
          redirect.type,
          redirect,
          type.unit,
        );
        var selector = redirect.name?.name ?? '';
        // In an unresolved redirect, `Query._private` is parsed as the
        // prefixed type `Query._private`. Resolve that ambiguity using the
        // source namespace before treating its final token as a constructor.
        if (target == null &&
            selector.isEmpty &&
            redirect.type.importPrefix != null) {
          target = type.unit.sources.resolveTypeNames(
            [redirect.type.importPrefix!.name.lexeme],
            redirect,
            type.unit,
          );
          selector = redirect.type.name.lexeme;
        }
        if (target == null || target.node is! ClassDeclaration) {
          return _unknown(caller, 'Unknown factory redirect');
        }
        // Identical formals avoid reinterpreting omitted defaults or losing a
        // named/positional binding while forwarding an unresolved call AST.
        final targetOwner = target.node as ClassDeclaration;
        final targetConstructor = targetOwner.body.members
            .whereType<ConstructorDeclaration>()
            .where((candidate) => (candidate.name?.lexeme ?? '') == selector)
            .firstOrNull;
        if (targetConstructor == null ||
            !_sameParameters(
              constructor.parameters,
              targetConstructor.parameters,
            ) ||
            selector.startsWith('_') && !identical(type.unit, target.unit)) {
          return _unknown(caller, 'Unsupported factory redirect arguments');
        }
        final values = _construct(
          target,
          selector,
          arguments,
          caller..active.add(constructor),
          runtime,
          Object(),
          accessUnit: type.unit,
        );
        for (final value in values) {
          value.frame.active.remove(constructor);
        }
        caller.active.remove(constructor);
        return values;
      }
      if (arguments == null) {
        return _unknown(caller, 'Missing factory arguments');
      }
      return runtime.invokeCallable(
        DartDeclaration(type.unit, constructor),
        arguments,
        caller,
      );
    }
    if (owner is ClassDeclaration &&
        (owner.extendsClause != null ||
            owner.withClause != null ||
            owner.implementsClause != null)) {
      return _unknown(caller, 'Inherited object initialization');
    }
    if (constructor != null &&
        (constructor.externalKeyword != null ||
            constructor.redirectedConstructor != null ||
            !(constructor.body is EmptyFunctionBody ||
                (constructor.body is BlockFunctionBody &&
                    (constructor.body as BlockFunctionBody)
                        .block
                        .statements
                        .isEmpty)) ||
            constructor.initializers.any(
              (initializer) => initializer is! ConstructorFieldInitializer,
            ))) {
      return _unknown(caller, 'Unreadable generative constructor');
    }
    if (caller.active.contains(owner) ||
        (constructor != null && caller.active.contains(constructor))) {
      return _unknown(caller, 'Recursive object initialization');
    }
    final positional = <Expression>[];
    final named = <String, Expression>{};
    for (final argument in arguments?.arguments ?? <Argument>[]) {
      if (argument is NamedArgument) {
        if (named.containsKey(argument.name.lexeme)) {
          return _unknown(caller, 'Duplicate constructor argument');
        }
        named[argument.name.lexeme] = argument.argumentExpression;
      } else {
        positional.add(argument.argumentExpression);
      }
    }
    final parameters =
        constructor?.parameters.parameters ?? <FormalParameter>[];
    final fields = <String, VariableDeclaration>{};
    for (final member in members.whereType<FieldDeclaration>()) {
      if (member.isStatic) continue;
      for (final variable in member.fields.variables) {
        if (fields.containsKey(variable.name.lexeme)) {
          return _unknown(caller, 'Duplicate object field');
        }
        fields[variable.name.lexeme] = variable;
      }
    }
    // Constructor parameters and field initializers need temporary lexical
    // bindings. They must not overwrite the enclosing receiver's fields or
    // make another instance's fields readable in a method with unknown `this`.
    // Anchor the backup alongside the pending object so branches clone mutable
    // values together with their aliases in the caller's environment.
    final bindings = <AstNode>[...parameters, ...fields.values];
    final present = caller.env.keys.toSet();
    var states = [caller.copy()];
    for (final state in states) {
      state.env[anchor] = RecordValue([
        ObjectValue(type, {}),
        RecordValue([
          for (final binding in bindings)
            state.env[binding] ?? UnknownValue('Absent constructor binding'),
        ], {}),
      ], {});
    }
    var position = 0;
    for (final parameter in parameters) {
      final supplied = parameter.isNamed
          ? named.remove(parameter.name?.lexeme)
          : position < positional.length
          ? positional[position++]
          : null;
      if (supplied == null && parameter.isRequired) {
        return _unknown(caller, 'Missing constructor argument');
      }
      final next = <StaticFrame>[];
      for (final state in states) {
        if (supplied != null) {
          for (final value in runtime.evaluate(supplied, state)) {
            value.frame.env[parameter] = value.value;
            next.add(value.frame);
          }
        } else if (parameter.defaultClause != null) {
          for (final value in runtime.evaluate(
            parameter.defaultClause!.value,
            state.withUnit(type.unit),
          )) {
            value.frame.env[parameter] = value.value;
            next.add(value.frame.withUnit(caller.unit));
          }
        } else {
          state.env[parameter] = ScalarValue(null);
          next.add(state);
        }
      }
      if (next.length > 32) {
        return _unknown(caller, 'Constructor variant limit');
      }
      states = next;
    }
    if (position != positional.length || named.isNotEmpty) {
      return _unknown(caller, 'Unsupported constructor arguments');
    }
    final initializers = <String, Expression>{};
    for (final initializer
        in constructor?.initializers ?? <ConstructorInitializer>[]) {
      final field = initializer as ConstructorFieldInitializer;
      if (initializers.containsKey(field.fieldName.name)) {
        return _unknown(caller, 'Duplicate field initializer');
      }
      initializers[field.fieldName.name] = field.expression;
    }
    var outcomes = [
      for (final state in states)
        StaticOutcome(
          (state.env[anchor] as RecordValue).positional.first,
          state.withUnit(type.unit),
        ),
    ];
    for (final outcome in outcomes) {
      outcome.frame.active.add(owner);
      if (constructor != null) outcome.frame.active.add(constructor);
    }
    for (final entry in fields.entries) {
      final variable = entry.value;
      final list = variable.parent as VariableDeclarationList;
      final formal = parameters
          .whereType<FieldFormalParameter>()
          .where((parameter) => parameter.name.lexeme == entry.key)
          .firstOrNull;
      final expression = initializers[entry.key] ?? variable.initializer;
      final next = <StaticOutcome>[];
      for (final prior in outcomes) {
        final List<StaticOutcome> values;
        if (list.isLate || (!list.isFinal && !list.isConst)) {
          values = _unknown(prior.frame, 'Mutable object field');
        } else if (formal != null) {
          if (expression != null) {
            return _unknown(caller, 'Duplicate final field initialization');
          }
          values = [
            StaticOutcome(
              prior.frame.env[formal] ?? UnknownValue('Unknown field argument'),
              prior.frame,
            ),
          ];
        } else if (expression != null) {
          values = runtime.evaluate(expression, prior.frame);
        } else {
          values = _unknown(prior.frame, 'Missing final field initialization');
        }
        for (final value in values) {
          final context = value.frame.env[anchor] as RecordValue;
          final object = context.positional.first as ObjectValue;
          final result = ObjectValue(type, {
            ...object.fields,
            entry.key: value.value,
          });
          value.frame.env[anchor] = RecordValue([
            result,
            context.positional[1],
          ], {});
          value.frame.env[variable] = value.value;
          next.add(StaticOutcome(result, value.frame));
        }
      }
      if (next.length > 32) return _unknown(caller, 'Object variant limit');
      outcomes = next;
    }
    final result = <StaticOutcome>[];
    for (final outcome in outcomes) {
      final context = outcome.frame.env.remove(anchor) as RecordValue;
      final backup = context.positional[1] as RecordValue;
      for (var index = 0; index < bindings.length; index++) {
        final binding = bindings[index];
        if (present.contains(binding)) {
          outcome.frame.env[binding] = backup.positional[index];
        } else {
          outcome.frame.env.remove(binding);
        }
      }
      result.add(
        StaticOutcome(
          context.positional.first,
          outcome.frame.withUnit(caller.unit)
            ..active.remove(owner)
            ..active.remove(constructor),
        ),
      );
    }
    return result;
  }
}

StaticOutcome _finishReceiver(
  StaticOutcome outcome,
  Object anchor,
  Map<String, VariableDeclaration> fields,
  Set<Object> present,
  DartUnit callerUnit,
) {
  final context = outcome.frame.env.remove(anchor) as RecordValue;
  final backup = context.positional[1] as RecordValue;
  var index = 0;
  for (final field in fields.values) {
    if (present.contains(field)) {
      outcome.frame.env[field] = backup.positional[index];
    } else {
      outcome.frame.env.remove(field);
    }
    index++;
  }
  outcome.frame.receiver = context.positional[2] is ObjectValue
      ? context.positional[2] as ObjectValue
      : null;
  return StaticOutcome(
    context.positional.first,
    outcome.frame.withUnit(callerUnit),
  );
}

bool _constructorWrites(ClassDeclaration owner, String name) =>
    owner.body.members.whereType<ConstructorDeclaration>().any(
      (constructor) =>
          constructor.parameters.parameters
              .whereType<FieldFormalParameter>()
              .any((parameter) => parameter.name.lexeme == name) ||
          constructor.initializers.whereType<ConstructorFieldInitializer>().any(
            (initializer) => initializer.fieldName.name == name,
          ),
    );

/// Private selectors cannot be overridden in another library. A final class
/// similarly excludes external subtypes. Parts and possible local overrides
/// are deliberately excluded rather than guessing the runtime receiver.
bool _safeDispatch(DartDeclaration type, String name) {
  final owner = type.node;
  if (owner is! ClassDeclaration ||
      !type.unit.readable ||
      _instanceMember(type, name) == null ||
      type.unit.unit.directives.any(
        (directive) =>
            directive is PartDirective || directive is PartOfDirective,
      )) {
    return false;
  }
  if (!name.startsWith('_') && owner.finalKeyword == null) return false;
  for (final declaration in type.unit.unit.declarations) {
    if (identical(declaration, owner)) continue;
    if (declaration is ClassTypeAlias) return false;
    if (declaration is ClassDeclaration &&
        declaration.withClause != null &&
        _mayBeSubtype(DartDeclaration(type.unit, declaration), owner, {})) {
      // A local subclass may obtain an overriding selector from a mixin even
      // when the subclass body declares no member with that name. An unknown
      // mixin is not evidence that the original implementation still wins.
      return false;
    }
    final members = switch (declaration) {
      ClassDeclaration() => declaration.body.members,
      MixinDeclaration() => declaration.body.members,
      EnumDeclaration() => declaration.body.members,
      _ => null,
    };
    if (members != null &&
        members.any(
          (member) =>
              member is MethodDeclaration && member.name.lexeme == name ||
              member is FieldDeclaration &&
                  member.fields.variables.any(
                    (field) => field.name.lexeme == name,
                  ),
        )) {
      return false;
    }
  }
  return true;
}

bool _mayBeSubtype(DartDeclaration type, AstNode target, Set<AstNode> seen) {
  if (identical(type.node, target)) return true;
  if (!type.unit.readable || !seen.add(type.node)) return true;
  final owner = type.node;
  if (owner is! ClassDeclaration) return true;
  final bases = [
    if (owner.extendsClause?.superclass case final NamedType parent) parent,
    ...?owner.implementsClause?.interfaces,
  ];
  for (final base in bases) {
    final declaration = type.unit.sources.resolveNamedType(
      base,
      base,
      type.unit,
    );
    if (declaration == null || _mayBeSubtype(declaration, target, seen)) {
      return true;
    }
  }
  return false;
}

// A final reference to a mutable collection is not an immutable declaration
// initializer. Its contents may have changed before this unknown instance was
// observed. Preserve scalar projections while leaving mutable contents opaque.
StaticValue _immutableValue(StaticValue value) => switch (value) {
  TextValue() || ScalarValue() || EnumValue() || UnknownValue() => value,
  RecordValue() => RecordValue(
    value.positional.map(_immutableValue).toList(),
    value.named.map((key, value) => MapEntry(key, _immutableValue(value))),
  ),
  ObjectValue() => ObjectValue(
    value.type,
    value.fields.map((key, value) => MapEntry(key, _immutableValue(value))),
    exact: value.exact,
  ),
  _ => UnknownValue('Mutable receiver initializer'),
};

bool _sameParameters(FormalParameterList left, FormalParameterList right) {
  if (left.parameters.length != right.parameters.length) return false;
  for (var index = 0; index < left.parameters.length; index++) {
    final a = left.parameters[index];
    final b = right.parameters[index];
    final leftDefault = a.defaultClause?.value;
    final rightDefault = b.defaultClause?.value;
    if (a.name?.lexeme != b.name?.lexeme ||
        a.isNamed != b.isNamed ||
        a.isRequired != b.isRequired ||
        leftDefault?.toSource() != rightDefault?.toSource() ||
        leftDefault != null && !_literalDefault(leftDefault) ||
        rightDefault != null && !_literalDefault(rightDefault)) {
      return false;
    }
  }
  return true;
}

bool _literalDefault(Expression expression) =>
    expression is SimpleStringLiteral ||
    expression is IntegerLiteral ||
    expression is DoubleLiteral ||
    expression is BooleanLiteral ||
    expression is NullLiteral;

AstNode? _instanceMember(DartDeclaration type, String name) {
  final members = switch (type.node) {
    ClassDeclaration() => (type.node as ClassDeclaration).body.members,
    EnumDeclaration() => (type.node as EnumDeclaration).body.members,
    _ => null,
  };
  if (members == null) return null;
  final matches = <AstNode>[];
  for (final member in members) {
    if (member is MethodDeclaration &&
        !member.isStatic &&
        member.name.lexeme == name &&
        !member.isSetter) {
      matches.add(member);
    } else if (member is FieldDeclaration && !member.isStatic) {
      matches.addAll(
        member.fields.variables.where(
          (variable) => variable.name.lexeme == name,
        ),
      );
    }
  }
  return matches.length == 1 ? matches.single : null;
}

final ArgumentList _emptyArguments =
    ((((parseString(content: 'void _() { _(); }').unit.declarations.single
                                    as FunctionDeclaration)
                                .functionExpression
                                .body
                            as BlockFunctionBody)
                        .block
                        .statements
                        .single
                    as ExpressionStatement)
                .expression
            as MethodInvocation)
        .argumentList;

List<StaticOutcome> _unknown(StaticFrame frame, String reason) => [
  StaticOutcome(UnknownValue(reason), frame),
];

List<String>? _names(Expression expression) => switch (expression) {
  SimpleIdentifier() => [expression.name],
  PrefixedIdentifier() => [expression.prefix.name, expression.identifier.name],
  PropertyAccess() =>
    expression.target == null
        ? null
        : switch (_names(expression.target!)) {
            final List<String> names => [
              ...names,
              expression.propertyName.name,
            ],
            _ => null,
          },
  MethodInvocation() =>
    expression.target == null
        ? [expression.methodName.name]
        : switch (expression.target is MethodInvocation ||
                  expression.target is InstanceCreationExpression
              ? null
              : _names(expression.target!)) {
            final List<String> names => [...names, expression.methodName.name],
            _ => null,
          },
  _ => null,
};
