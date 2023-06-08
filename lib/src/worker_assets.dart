import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';

import 'annotations/marshallers/marshalling_info.dart';
import 'annotations/squadron_library.dart';
import 'annotations/squadron_method_annotation.dart';
import 'annotations/squadron_service_annotation.dart';
import '_overrides.dart';

class WorkerAssets {
  WorkerAssets(BuildStep buildStep, this._squadron, this.service,
      this.formatOutput, this.header)
      : workerClassName = '${service.name}Worker',
        workerPoolClassName = '${service.name}WorkerPool',
        operationsMixinName = '\$${service.name}Operations',
        serviceInitializerName = '\$${service.name}Initializer',
        serviceActivator = '${service.name}Activator',
        _inputId = buildStep.inputId,
        _writeCode = buildStep.writeAsString {
    for (var output in buildStep.allowedOutputs) {
      final path = output.path.toLowerCase();
      if (service.vm && path.endsWith('.vm.g.dart')) {
        _vmOutput = output;
      } else if (service.web && path.endsWith('.web.g.dart')) {
        _webOutput = output;
      } else if (path.endsWith('.stub.g.dart')) {
        _xplatOutput = output;
      } else if (path.endsWith('.activator.g.dart')) {
        _activatorOutput = output;
      }
    }
  }

  final AssetId _inputId;
  AssetId? _vmOutput;
  AssetId? _webOutput;
  AssetId? _xplatOutput;
  AssetId? _activatorOutput;

  final Future<void> Function(AssetId, FutureOr<String>) _writeCode;
  final String Function(String source) formatOutput;

  final SquadronServiceAnnotation service;
  final String header;

  final SquadronLibrary _squadron;

  final String operationsMixinName;
  final String workerClassName;
  final String workerPoolClassName;
  final String serviceInitializerName;
  final String serviceActivator;

  Future<void> generateCrossPlatformCode() async {
    final output = _xplatOutput;
    if (output != null && _vmOutput != null && _webOutput != null) {
      await _writeCode(output, formatOutput('''
          $header

          ${_squadron.entryPointTypeName is DynamicType ? '' : 'import \'package:squadron/squadron.dart\';'}

          ${_unimplemented('${_squadron.entryPointTypeName} \$get$serviceActivator()')}
        '''));
    }
  }

  Future<void> generateVmCode(String? logger) async {
    final output = _vmOutput;
    if (output != null) {
      final serializationType = _squadron.serializationTypeName.toString();
      final serviceImport = _getRelativePath(_inputId, output);
      await _writeCode(output, formatOutput('''
          $header

          import 'package:squadron/squadron.dart';
          import '$serviceImport';

          // VM entry point
          void _start($serializationType command) => run($serviceInitializerName, command, $logger);

          ${_squadron.entryPointTypeName} \$get$serviceActivator() => _start;
        '''));
    }
  }

  Future<void> generateWebCode(String? logger) async {
    final output = _webOutput;
    if (output != null) {
      final serviceImport = _getRelativePath(_inputId, output);
      final workerUrl = service.baseUrl.isEmpty
          ? '${output.path}.js'
          : '${service.baseUrl}/${output.pathSegments.last}.js';
      await _writeCode(output, formatOutput('''
          $header

          import 'package:squadron/squadron.dart';
          import '$serviceImport';

          // Web entry point
          void main() => run($serviceInitializerName, null, $logger);

          ${_squadron.entryPointTypeName} \$get$serviceActivator() => '$workerUrl';
        '''));
    }
  }

  Future<void> generateActivatorCode() async {
    final output = _activatorOutput;
    if (output != null) {
      if (_xplatOutput != null && _webOutput != null && _vmOutput != null) {
        final stubImport = _getRelativePath(_xplatOutput!, output);
        final webImport = _getRelativePath(_webOutput!, output);
        final vmImport = _getRelativePath(_vmOutput!, output);
        await _writeCode(output, formatOutput('''
          $header

          import '$stubImport'
            if (dart.library.js) '$webImport'
            if (dart.library.html) '$webImport'
            if (dart.library.io) '$vmImport';

          final \$$serviceActivator = \$get$serviceActivator();
        '''));
      } else if (_vmOutput != null) {
        final vmImport = _getRelativePath(_vmOutput!, output);
        await _writeCode(output, formatOutput('''
          $header

          import '$vmImport';

          final \$$serviceActivator = \$get$serviceActivator();
        '''));
      } else if (_webOutput != null) {
        final webImport = _getRelativePath(_webOutput!, output);
        await _writeCode(output, formatOutput('''
          $header

          import '$webImport';

          final \$$serviceActivator = \$get$serviceActivator();
        '''));
      }
    }
  }

  Stream<String> generateMapWorkerAndPool(bool withFinalizers) async* {
    final commands = <SquadronMethodAnnotation>[];
    final unimplemented = <SquadronMethodAnnotation>[];

    for (var method in service.methods) {
      // load command info
      final command = SquadronMethodAnnotation.load(method);
      if (method.name.startsWith('_') || command == null) {
        // not a Squadron command: override as unimplemented in worker / pool
        unimplemented.add(SquadronMethodAnnotation.unimplemented(method));
      } else {
        // Squadron command: override to use worker / pool
        commands.add(command);
      }
    }

    commands.sort((a, b) => a.name.compareTo(b.name));
    for (var i = 0; i < commands.length; i++) {
      commands[i].setNum(i + 1);
    }

    yield _generateOperationMap(commands);

    yield _generateServiceInitializer();

    final generators = [
      withFinalizers ? _generateFinalizableWorker : _generateWorker,
      if (service.pool)
        withFinalizers ? _generateFinalizableWorkerPool : _generateWorkerPool,
    ];

    for (var generator in generators) {
      yield generator(commands, unimplemented);
    }
  }

  String _generateOperationMap(List<SquadronMethodAnnotation> commands) => '''
        // Operations map for ${service.name}
        mixin $operationsMixinName on WorkerService {
          @override
          late final Map<int, CommandHandler> operations = _getOperations(this as ${service.name});

          ${commands.map(_generateCommandIds).join('\n')}

          static Map<int, CommandHandler> _getOperations(${service.name} svc) => {
            ${commands.map(_generateCommandHandler).join(',\n')}
          };
        }
      ''';

  String _generateServiceInitializer() => '''
        // Service initializer
        ${service.name} $serviceInitializerName(WorkerRequest startRequest)
            => ${service.name}(${service.parameters.deserialize('startRequest')});
      ''';

  String _generateWorker(List<SquadronMethodAnnotation> commands,
      List<SquadronMethodAnnotation> unimplemented) {
    final serialized = service.parameters.serialize();
    var activationsArgs = serialized.isEmpty
        ? serviceActivator
        : '$serviceActivator, args: [$serialized]';

    var params = service.parameters;
    if (_squadron.platformWorkerHookTypeName != null) {
      params = params.clone();
      final pwh = params.addOptional(
          'platformWorkerHook', _squadron.platformWorkerHookTypeName!);
      activationsArgs += ', ${pwh.toFormalArgument()}';
    }

    return '''
        // Worker for ${service.name}
        class $workerClassName
          extends Worker with $operationsMixinName
          implements ${service.name} {
          
          $workerClassName($params) : super(\$$activationsArgs);

          ${service.fields.values.map(_generateField).join('\n\n')}

          ${commands.map(_generateWorkerMethod).join('\n\n')}

          @override
          Map<int, CommandHandler> get operations => WorkerService.noOperations;

          ${unimplemented.map(_generateUnimplemented).join('\n\n')}

          ${service.accessors.map(_generateUnimplementedAcc).join('\n\n')}
        }
      ''';
  }

  String _generateFinalizableWorker(List<SquadronMethodAnnotation> commands,
      List<SquadronMethodAnnotation> unimplemented) {
    final serialized = service.parameters.serialize();
    var activationArgs = serialized.isEmpty
        ? serviceActivator
        : '$serviceActivator, args: [$serialized]';

    var params = service.parameters;
    if (_squadron.platformWorkerHookTypeName != null) {
      params = params.clone();
      final pwh = params.addOptional(
          'platformWorkerHook', _squadron.platformWorkerHookTypeName!);
      activationArgs += ', ${pwh.toFormalArgument()}';
    }

    return '''
        // Worker for ${service.name}
        class _$workerClassName
          extends Worker with $operationsMixinName
          implements ${service.name} {
          
          _$workerClassName($params) : super(\$$activationArgs);

          ${service.fields.values.map(_generateField).join('\n\n')}

          ${commands.map(_generateWorkerMethod).join('\n\n')}

          @override
          Map<int, CommandHandler> get operations => WorkerService.noOperations;

          ${unimplemented.map(_generateUnimplemented).join('\n\n')}

          ${service.accessors.map(_generateUnimplementedAcc).join('\n\n')}

          final Object _detachToken = Object();
        }

        // Finalizable worker wrapper for ${service.name}
        class $workerClassName implements _$workerClassName {
          
          $workerClassName($params) : _worker = _$workerClassName(${params.toFormalArguments()}) {
            _finalizer.attach(this, _worker, detach: _worker._detachToken);
          }

          ${service.fields.values.map((f) => _forwardField(f, '_worker')).join('\n\n')}

          final _$workerClassName _worker;

          static final Finalizer<_$workerClassName> _finalizer = Finalizer<_$workerClassName>((w) {
            try {
              _finalizer.detach(w._detachToken);
              w.stop();
            } catch (ex) {
              // finalizers must not throw
            }
          });

          ${commands.map((cmd) => _forwardMethod(cmd, '_worker')).join('\n\n')}

          @override
          Map<int, CommandHandler> get operations => _worker.operations;

          ${unimplemented.map((cmd) => _forwardMethod(cmd, '_worker')).join('\n\n')}

          ${service.accessors.map((acc) => _forwardAccessor(acc, '_worker')).join('\n\n')}

          ${workerOverrides.entries.map((e) => _forwardOverride(e.key, '_worker', e.value)).join('\n\n')}
        }
      ''';
  }

  String _generateWorkerPool(List<SquadronMethodAnnotation> commands,
      List<SquadronMethodAnnotation> unimplemented) {
    var poolParams = service.parameters.clone();
    poolParams.addOptional(
        'concurrencySettings', _squadron.concurrencySettingsTypeName);
    var serviceParams = service.parameters;
    if (_squadron.platformWorkerHookTypeName != null) {
      poolParams.addOptional(
          'platformWorkerHook', _squadron.platformWorkerHookTypeName!);
      serviceParams = serviceParams.clone();
      serviceParams.addOptional(
          'platformWorkerHook', _squadron.platformWorkerHookTypeName!);
    }

    return '''
          // Worker pool for ${service.name}
          class $workerPoolClassName
            extends WorkerPool<$workerClassName> with $operationsMixinName
            implements ${service.name} {

            $workerPoolClassName($poolParams) : super(
                () => $workerClassName(${serviceParams.toFormalArguments()}),
                concurrencySettings: concurrencySettings);

            ${service.fields.values.map(_generateField).join('\n\n')}

            ${commands.map(_generatePoolMethod).join('\n\n')}

            @override
            Map<int, CommandHandler> get operations => WorkerService.noOperations;

            ${unimplemented.map(_generateUnimplemented).join('\n\n')}

            ${service.accessors.map(_generateUnimplementedAcc).join('\n\n')}
          }
        ''';
  }

  String _generateFinalizableWorkerPool(List<SquadronMethodAnnotation> commands,
      List<SquadronMethodAnnotation> unimplemented) {
    var poolParams = service.parameters.clone();
    var serviceParams = service.parameters;
    poolParams.addOptional(
        'concurrencySettings', _squadron.concurrencySettingsTypeName);
    if (_squadron.platformWorkerHookTypeName != null) {
      poolParams.addOptional(
          'platformWorkerHook', _squadron.platformWorkerHookTypeName!);
      serviceParams = serviceParams.clone();
      serviceParams.addOptional(
          'platformWorkerHook', _squadron.platformWorkerHookTypeName!);
    }

    return '''
          // Worker pool for ${service.name}
          class _$workerPoolClassName
            extends WorkerPool<$workerClassName> with $operationsMixinName
            implements ${service.name} {

            _$workerPoolClassName($poolParams) : super(
                () => $workerClassName(${serviceParams.toFormalArguments()}),
                concurrencySettings: concurrencySettings);

            ${service.fields.values.map(_generateField).join('\n\n')}

            ${commands.map(_generatePoolMethod).join('\n\n')}

            @override
            Map<int, CommandHandler> get operations => WorkerService.noOperations;

            ${unimplemented.map(_generateUnimplemented).join('\n\n')}

            ${service.accessors.map(_generateUnimplementedAcc).join('\n\n')}

            final Object _detachToken = Object();
          }

        // Finalizable worker pool wrapper for ${service.name}
        class $workerPoolClassName implements _$workerPoolClassName {
          
          $workerPoolClassName($poolParams) : _pool = _$workerPoolClassName(${poolParams.toFormalArguments()}) {
            _finalizer.attach(this, _pool, detach: _pool._detachToken);
          }

          ${service.fields.values.map((f) => _forwardField(f, '_pool')).join('\n\n')}

          final _$workerPoolClassName _pool;

          static final Finalizer<_$workerPoolClassName> _finalizer = Finalizer<_$workerPoolClassName>((p) {
            try {
              _finalizer.detach(p._detachToken);
              p.stop();
            } catch (ex) {
              // finalizers must not throw
            }
          });

          ${commands.map((cmd) => _forwardMethod(cmd, '_pool')).join('\n\n')}

          @override
          Map<int, CommandHandler> get operations => _pool.operations;

          ${unimplemented.map((cmd) => _forwardMethod(cmd, '_pool')).join('\n\n')}

          ${service.accessors.map((acc) => _forwardAccessor(acc, '_pool')).join('\n\n')}

          ${workerPoolOverrides.entries.map((e) => _forwardOverride(e.key, '_pool', e.value)).join('\n\n')}
        }
        ''';
  }

  String _generateCommandIds(SquadronMethodAnnotation cmd) =>
      'static const int ${cmd.id} = ${cmd.num};';

  String _generateCommandHandler(SquadronMethodAnnotation cmd) {
    final serviceCall = 'svc.${cmd.name}(${cmd.parameters.deserialize('req')})';
    if (cmd.needsSerialization && !cmd.serializedResult.isIdentity) {
      if (cmd.isStream) {
        return '${cmd.id}: (req) => $serviceCall.${cmd.continuation}((\$res) => ${cmd.serializedResult('\$res')})';
      } else {
        return '${cmd.id}: (req) async => ${cmd.serializedResult('(await $serviceCall)')}';
      }
    } else {
      return '${cmd.id}: (req) => $serviceCall';
    }
  }

  String _generateField(FieldElement field) => '''
      @override
      ${field.isFinal ? 'final ' : ''}${field.type} ${field.name};
    ''';

  String _unimplemented(String declaration, {bool override = false}) => '''
      ${override ? '@override' : ''}
      $declaration => throw UnimplementedError();
    ''';

  String _generateUnimplemented(SquadronMethodAnnotation cmd) =>
      _unimplemented(cmd.declaration, override: true);

  String _generateUnimplementedAcc(PropertyAccessorElement acc) {
    final declaration = acc.isGetter
        ? '${acc.returnType} get ${acc.name}'
        : 'set ${acc.name.replaceAll('=', '')}(${acc.returnType} value)';
    return _unimplemented(declaration, override: true);
  }

  String _generateWorkerMethod(SquadronMethodAnnotation cmd) {
    var deserialize = '';
    if (cmd.needsSerialization && !cmd.deserializedResult.isIdentity) {
      deserialize =
          '.${cmd.continuation}((\$res) => ${cmd.deserializedResult('\$res')})';
    }
    return '''
      @override
      ${cmd.declaration} => ${cmd.workerExecutor}(
            $operationsMixinName.${cmd.id}, 
            args: [ ${cmd.parameters.serialize()} ], 
            ${cmd.cancellationToken != null ? 'token: ${cmd.cancellationToken},' : ''}
            ${cmd.inspectRequest ? 'inspectRequest: true,' : ''}
            ${cmd.inspectResponse ? 'inspectResponse: true,' : ''}
          )$deserialize;
    ''';
  }

  String _generatePoolMethod(SquadronMethodAnnotation cmd) => '''
      @override
      ${cmd.declaration} => ${cmd.poolExecutor}((\$w) => \$w.${cmd.name}(${cmd.parameters.toFormalArguments()}));
    ''';

  String _forwardField(FieldElement field, String target) {
    if (field.isFinal) {
      return '''
          @override
          ${field.type} get ${field.name} => $target.${field.name};
        ''';
    } else {
      return '''
          @override
          ${field.type} get ${field.name} => $target.${field.name};

          @override
          set ${field.name}(${field.type} value) => $target.${field.name} = value;
        ''';
    }
  }

  String _forwardMethod(SquadronMethodAnnotation cmd, String target) {
    return '''
      @override
      ${cmd.declaration} => $target.${cmd.name}(${cmd.parameters.toFormalArguments()});
    ''';
  }

  String _forwardAccessor(PropertyAccessorElement acc, String target) {
    return acc.isGetter
        ? '''
            @override
            ${acc.returnType} get ${acc.name} => $target.${acc.name};
          '''
        : '''
            @override
            set ${acc.name.replaceAll('=', '')}(${acc.returnType} value) => $target.${acc.name}(value);
          ''';
  }

  String _forwardOverride(
      String declaration, String target, String implementation) {
    return '''
      @override
      ${declaration.replaceAll(r'$workerClassName', workerClassName)} => $target.$implementation;
    ''';
  }

  static String _getRelativePath(AssetId target, AssetId current) {
    final targetSegments = target.pathSegments;
    final currentSegments = current.pathSegments;

    while (targetSegments.isNotEmpty &&
        currentSegments.isNotEmpty &&
        targetSegments.first == currentSegments.first) {
      targetSegments.removeAt(0);
      currentSegments.removeAt(0);
    }

    while (currentSegments.length > 1) {
      targetSegments.insert(0, '..');
      currentSegments.removeAt(0);
    }

    return targetSegments.join('/');
  }
}
