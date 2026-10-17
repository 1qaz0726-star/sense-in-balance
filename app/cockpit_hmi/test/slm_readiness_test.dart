import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/slm.dart';
import 'package:cockpit_hmi/slm_model_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late SlmModelStore store;
  late SlmModelManifest manifest;
  late File modelFile;
  late List<String> events;
  final instances = <Slm>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('slm-readiness-');
    store = SlmModelStore(root);
    final bytes = utf8.encode('tiny verified model fixture, no native runtime');
    manifest = SlmModelManifest(
      id: 'readiness-fixture',
      label: 'Readiness test',
      source: 'local-test',
      sourceRevision: 'no-real-model',
      sha256Hex: sha256.convert(bytes).toString(),
      bytes: bytes.length,
    );
    modelFile = File('${root.path}/fixture.litertlm');
    await modelFile.writeAsBytes(bytes);
    events = [];
    gGemmaInitError = null;
  });

  tearDown(() async {
    for (final slm in instances) {
      if (slm.ready) await slm.unload();
      slm.dispose();
    }
    instances.clear();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      root.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('slm-readiness-'),
    );
    await root.delete(recursive: true);
  });

  Slm create(Future<InferenceModel> Function(PreferredBackend, int) load) {
    final slm = Slm.forTesting(
      modelStore: () async => store,
      installModel: (_) async => events.add('install'),
      loadModel: (backend, tokens) async {
        events.add('open:${backend.name}:$tokens');
        return load(backend, tokens);
      },
    );
    instances.add(slm);
    return slm;
  }

  test(
    'ready remains false until actual nonempty warm-up; public calls cannot enter candidate',
    () async {
      final gate = Completer<void>();
      final model = _Model(
        'gpu',
        events,
        response: () async* {
          await gate.future;
          yield '<silent>';
        },
      );
      final slm = create((_, _) async => model);
      final loading = slm.selectModel(manifest, file: modelFile);
      await until(() => model.sessions.isNotEmpty);
      expect(slm.phase, SlmPhase.loading);
      expect(slm.ready, false);
      expect(slm.backend, isEmpty);
      expect(slm.detail, contains('首次暖機'));
      await expectLater(
        slm.generate('test system', 'must not enter'),
        throwsStateError,
      );
      expect(model.sessions.length, 1);
      gate.complete();
      await loading;
      expect(slm.ready, true);
      expect(slm.backend, 'GPU');
      expect(model.sessions.single.closed, true);
      expect(model.sampling.single, {
        'temperature': 0.2,
        'randomSeed': 42,
        'topK': 1,
      });
      expect(
        model.sessions.single.messages.single.text,
        '$kRepairSystemPrompt\n\n'
        '{"pending":{},"unresolved_text":null,"clarification":null,'
        '"user_text":"導航提示維持原樣。"}',
      );
      expect(model.sessions.single.messages.single.isUser, true);
      expect(slm.supportsPhrasing, false);
      await expectLater(slm.phrase('不可將修復 JSON 當語音'), throwsStateError);
      expect(model.sessions.length, 1);
    },
  );

  test(
    'GPU init success but first session/stream failure closes GPU before CPU fallback',
    () async {
      for (final failAtSession in [true, false]) {
        events.clear();
        final gpu = _Model(
          'gpu',
          events,
          createError: failAtSession
              ? StateError('Can not find OpenCL library')
              : null,
          response: () =>
              Stream.error(StateError('Can not find OpenCL library')),
        );
        final cpu = _Model('cpu', events);
        final slm = create(
          (backend, _) async => backend == PreferredBackend.gpu ? gpu : cpu,
        );
        await slm.selectModel(manifest, file: modelFile);
        expect(slm.ready, true);
        expect(slm.backend, 'CPU');
        expect(gpu.closeCount, 1);
        expect(
          events.indexOf('close-model:gpu'),
          lessThan(events.indexOf('open:cpu:2048')),
        );
        expect(cpu.sessions.length, 1);
        expect(slm.detail, contains('已改用 CPU'));
        expect(slm.detail, contains('OpenCL'));
      }
    },
  );

  test(
    'both backend generations fail: close both and expose error, never ready',
    () async {
      final gpu = _Model(
        'gpu',
        events,
        createError: StateError('OpenCL unavailable'),
      );
      final cpu = _Model(
        'cpu',
        events,
        response: () => Stream.error(StateError('CPU generation failed')),
      );
      final slm = create(
        (backend, _) async => backend == PreferredBackend.gpu ? gpu : cpu,
      );
      await expectLater(
        slm.selectModel(manifest, file: modelFile),
        throwsStateError,
      );
      expect(slm.phase, SlmPhase.error);
      expect(slm.ready, false);
      expect(slm.backend, isEmpty);
      expect(slm.detail, contains('OpenCL'));
      expect(slm.detail, contains('CPU generation failed'));
      expect(gpu.closeCount, 1);
      expect(cpu.closeCount, 1);
      await expectLater(slm.generate('system', 'input'), throwsStateError);
    },
  );

  test(
    'empty warm-up stream is not readiness proof and falls back after closing',
    () async {
      final gpu = _Model('gpu', events, response: () => const Stream.empty());
      final cpu = _Model('cpu', events);
      final slm = create(
        (backend, _) async => backend == PreferredBackend.gpu ? gpu : cpu,
      );
      await slm.selectModel(manifest, file: modelFile);
      expect(slm.backend, 'CPU');
      expect(slm.ready, true);
      expect(gpu.closeCount, 1);
      expect(slm.detail, contains('暖機未產生文字'));
    },
  );

  test(
    'warmUp=false strict probe adds no generation and keeps request sampling/message unchanged',
    () async {
      final model = _Model('gpu', events);
      final slm = create((_, _) async => model);
      await slm.selectModel(
        manifest,
        file: modelFile,
        preferredBackend: PreferredBackend.gpu,
        warmUp: false,
        maxTokens: 2048,
      );
      expect(slm.ready, true);
      expect(slm.backend, 'GPU');
      expect(model.sessions, isEmpty);
      expect(events.where((e) => e.startsWith('open:')), ['open:gpu:2048']);
      expect(
        await slm.generate('explicit system', 'explicit prompt'),
        '<silent>',
      );
      expect(model.sessions.length, 1);
      expect(
        model.sessions.single.messages.single.text,
        'explicit system\n\nexplicit prompt',
      );
      expect(model.sampling.single, {
        'temperature': 0.2,
        'randomSeed': 42,
        'topK': 1,
      });
    },
  );

  test(
    'explicit GPU never silently tries CPU on initialization or warm-up failure',
    () async {
      for (final warmUp in [false, true]) {
        events.clear();
        final model = _Model(
          'gpu',
          events,
          createError: StateError('GPU generation error'),
        );
        final slm = create((_, _) async {
          if (!warmUp) throw StateError('GPU initialization error');
          return model;
        });
        await expectLater(
          slm.selectModel(
            manifest,
            file: modelFile,
            preferredBackend: PreferredBackend.gpu,
            warmUp: warmUp,
          ),
          throwsStateError,
        );
        expect(slm.phase, SlmPhase.error);
        expect(events.where((e) => e.startsWith('open:')), ['open:gpu:2048']);
        expect(model.closeCount, warmUp ? 1 : 0);
      }
    },
  );

  test(
    'failed candidate close stops fallback instead of overlapping uncertain resources',
    () async {
      final model = _Model(
        'gpu',
        events,
        createError: StateError('OpenCL missing'),
        closeError: StateError('close failed'),
      );
      final slm = create((_, _) async => model);
      await expectLater(
        slm.selectModel(manifest, file: modelFile),
        throwsStateError,
      );
      expect(slm.ready, false);
      expect(slm.phase, SlmPhase.error);
      expect(slm.detail, contains('模型關閉失敗'));
      expect(events.where((e) => e.startsWith('open:')), ['open:gpu:2048']);
    },
  );

  test(
    'public generation queue waits for session close before starting next request',
    () async {
      final closeGate = Completer<void>();
      final model = _Model('gpu', events, firstSessionCloseGate: closeGate);
      final slm = create((_, _) async => model);
      await slm.selectModel(
        manifest,
        file: modelFile,
        preferredBackend: PreferredBackend.gpu,
        warmUp: false,
      );
      final first = slm.generate('system', 'first');
      final second = slm.generate('system', 'second');
      await until(() => events.contains('close-session:gpu:0'));
      expect(model.sessions.length, 1);
      closeGate.complete();
      expect(await first, '<silent>');
      expect(await second, '<silent>');
      expect(model.sessions.length, 2);
      expect(model.sessions.map((s) => s.messages.single.text), [
        'system\n\nfirst',
        'system\n\nsecond',
      ]);
    },
  );
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('test stage not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _Model extends InferenceModel {
  _Model(
    this.name,
    this.events, {
    Stream<String> Function()? response,
    this.createError,
    this.closeError,
    this.firstSessionCloseGate,
  }) : response = response ?? (() => Stream.value('<silent>'));
  final String name;
  final List<String> events;
  final Stream<String> Function() response;
  final Object? createError;
  final Object? closeError;
  final Completer<void>? firstSessionCloseGate;
  final sessions = <_Session>[];
  final sampling = <Map<String, Object>>[];
  int closeCount = 0;
  @override
  int get maxTokens => 2048;
  @override
  ModelFileType get fileType => ModelFileType.task;
  @override
  InferenceModelSession? get session => sessions.isEmpty ? null : sessions.last;
  @override
  Future<InferenceModelSession> createSession({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
  }) async {
    events.add('session:$name');
    sampling.add({
      'temperature': temperature,
      'randomSeed': randomSeed,
      'topK': topK,
    });
    if (createError case final error?) throw error;
    final created = _Session(
      '$name:${sessions.length}',
      events,
      response,
      sessions.isEmpty ? firstSessionCloseGate : null,
    );
    sessions.add(created);
    return created;
  }

  @override
  Future<void> close() async {
    closeCount++;
    events.add('close-model:$name');
    if (closeError case final error?) throw error;
  }
}

class _Session implements InferenceModelSession {
  _Session(this.name, this.events, this.response, this.closeGate);
  final String name;
  final List<String> events;
  final Stream<String> Function() response;
  final Completer<void>? closeGate;
  final messages = <Message>[];
  bool closed = false;
  @override
  Future<void> addQueryChunk(Message message) async => messages.add(message);
  @override
  Stream<String> getResponseAsync() => response();
  @override
  Future<String> getResponse() => response().join();
  @override
  Future<int> sizeInTokens(String text) async => text.length;
  @override
  Future<void> stopGeneration() async {}
  @override
  Future<void> close() async {
    events.add('close-session:$name');
    if (closeGate != null) await closeGate!.future;
    closed = true;
  }
}
