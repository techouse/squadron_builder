import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:squadron/squadron_annotations.dart';

import 'annotations/squadron_library.dart';
import 'annotations/squadron_service_reader.dart';
import 'build_step_events.dart';
import 'version.dart';
import 'worker_assets.dart';

/// Alias for a code formatting function.
typedef Formatter = String Function(String source);

/// Code generator for Squadron workers.
class WorkerGenerator extends GeneratorForAnnotation<SquadronService> {
  WorkerGenerator({Formatter? formatOutput, bool withFinalizers = false})
      : _formatOutput = formatOutput ?? _noFormatting,
        _withFinalizers = withFinalizers {
    _buildStepEventStream.stream.listen(_process);
  }

  late final String _header = '''
      // GENERATED CODE - DO NOT MODIFY BY HAND
      
      // **************************************************************************
      // Generator: $this
      // **************************************************************************
      ''';

  final bool _withFinalizers;
  final Formatter _formatOutput;

  final _buildStepEventStream = StreamController<BuildStepEvent>();

  final _results = <BuildStep, BuildStepCodeEvent>{};

  void _process(BuildStepEvent event) {
    if (event is BuildStepCodeEvent) {
      _registerAssetCode(event);
    } else if (event is BuildStepDoneEvent) {
      _writeAssetCode(event);
    } else {
      log.warning('Discarding unknown build step event ${event.runtimeType}');
    }
  }

  void _registerAssetCode(BuildStepCodeEvent newResult) {
    final result = _results[newResult.buildStep];
    if (result == null) {
      // first result: register
      _results[newResult.buildStep] = newResult;
    } else {
      // merge additional results as they come through
      result.mergeWith(newResult);
    }
  }

  void _writeAssetCode(BuildStepDoneEvent done) {
    final result = _results[done.buildStep];
    if (result != null) {
      _results.remove(done.buildStep);
      final insertHeader = [_header].followedBy;
      for (var asset in result.assets) {
        var code = insertHeader(result.getCode(asset)).join('\n\n');
        try {
          code = _formatOutput(code);
        } catch (ex) {
          log.severe(
              'An exception occurred while formatting code for ${asset.uri}: $ex');
        }
        result.buildStep.writeAsString(asset, code);
      }
    }
  }

  static final _squadronUri = Uri.parse('package:squadron/squadron.dart');
  SquadronLibrary? _squadron;

  @override
  Future<String> generate(LibraryReader library, BuildStep buildStep) async {
    // load Squadron main library
    if (_squadron == null) {
      final sqAssetId = AssetId.resolve(_squadronUri);
      final sqLibrary = await buildStep.resolver.libraryFor(sqAssetId);
      _squadron = SquadronLibrary(sqLibrary);
    }

    // generate code
    final result = await super.generate(library, buildStep);

    // success, trigger code generation for additional assets associated to this libreay
    _buildStepEventStream.add(BuildStepDoneEvent(buildStep));

    return result;
  }

  @override
  Stream<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async* {
    final classElt = element;
    if (classElt is! ClassElement) return;

    // implementation moved to specific methods to facilitate unit tests
    final service = SquadronServiceReader.load(classElt)!;

    final assets = WorkerAssets(buildStep, _squadron!, service);

    final codeEvent = BuildStepCodeEvent(buildStep, classElt);
    assets.generateVmCode(codeEvent, service.logger);
    assets.generateWebCode(codeEvent, service.logger);
    assets.generateCrossPlatformCode(codeEvent);
    assets.generateActivatorCode(codeEvent);
    _buildStepEventStream.add(codeEvent);

    await for (var code in assets.generateMapWorkerAndPool(_withFinalizers)) {
      yield code;
    }
  }

  @override
  String toString() => '$runtimeType $version';
}

String _noFormatting(String source) => source;
