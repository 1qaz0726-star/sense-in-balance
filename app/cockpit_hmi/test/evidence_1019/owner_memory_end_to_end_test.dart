// 昱羲 10/19 的端到端證據測試；MEM-01 修正後，結尾改成驗證「已修好」。
// Run with --dart-define=OPENROUTER_API_KEY=evidence-only-dummy-key.
// HTTP is intercepted in-process; no external API, key or real model is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/owner_memory.dart';
import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_screen.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const phrase = '讓後座的小孩好睡一點';
const expected = {
  CabinSetting.rearFan: RequestedChange.decrease,
  CabinSetting.mediaVolume: RequestedChange.decrease,
};

class FakeCloud extends HttpOverrides {
  bool online = true;
  int generationCalls = 0;
  final requests = <String>[];
  String answer =
      '{"changes":{"rearFan":"decrease","mediaVolume":"decrease"},"clarification":null}';
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);
}

class _Client implements HttpClient {
  _Client(this.fake);
  final FakeCloud fake;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _request(url, false);
  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _request(url, true);
  HttpClientRequest _request(Uri url, bool post) {
    if (url.host != 'openrouter.ai') {
      throw StateError('External request blocked: ${url.host}');
    }
    fake.requests.add('${post ? 'POST' : 'GET'} ${url.path}');
    if (!fake.online) throw const SocketException('evidence offline');
    return _Request(fake, post);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.fake, this.post);
  final FakeCloud fake;
  final bool post;
  @override
  final HttpHeaders headers = _Headers();
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() async {
    if (post) fake.generationCalls++;
    return _Response(
      post
          ? jsonEncode({
              'choices': [
                {
                  'message': {'content': fake.answer},
                },
              ],
            })
          : '{}',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.body);
  final String body;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real RepairScreen: complete persisted recall path plus driver-origin stale-text characterization',
    (tester) async {
      const key = String.fromEnvironment('OPENROUTER_API_KEY');
      expect(
        key,
        'evidence-only-dummy-key',
        reason: 'Only the public dummy key may be used',
      );
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('sib-1019-memory-'),
      ))!;
      final cloud = FakeCloud();
      final previousOverride = HttpOverrides.current;
      HttpOverrides.global = cloud;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => directory.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (call) async => call.method == 'isLanguageAvailable' ? true : 1,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('sense_in_balance/repair_speech'),
        (call) async => false,
      );
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      await tester.pumpWidget(const MaterialApp(home: RepairScreen()));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      final dynamic state = tester.state(find.byType(RepairScreen));
      final RepairController controller = state.controller;
      final RepairCollaboration collaboration = state.collaboration;
      final CabinPolicy? policy = state.policy;
      var sourceSequence = 1000;
      void clearVehicleSources() {
        if (policy == null) return;
        for (final source in [
          CabinPolicy.drivingSource,
          CabinPolicy.safetySource,
        ]) {
          policy.observe(
            CabinAttentionFrame(
              sourceId: source,
              sourceSession:
                  '${state.sourceSession}-${source == CabinPolicy.drivingSource ? 'driving' : 'safety'}',
              sequence: ++sourceSequence,
              episodeId: 'evidence-clear-$source',
              sampledAt: policy.monotonicNow,
            ),
          );
        }
      }

      final File file = File('${directory.path}/owner_memory.json');
      try {
        clearVehicleSources();
        state.cloudLink.online = true;
        state.input.text = phrase;
        await tester.runAsync(
          () => HttpOverrides.runZoned(
            () async => state.submit(),
            createHttpClient: (_) => _Client(cloud),
          ),
        );
        await tester.pump();
        expect(controller.snapshot.patchSource, 'cloud');
        expect(controller.snapshot.pending, expected);
        expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
        expect((state.ownerMemory as OwnerMemory).entries, isEmpty);
        expect(
          await tester.runAsync(() => file.exists()),
          isFalse,
          reason: 'Unconfirmed proposal must not persist',
        );
        final driver = Object();
        expect(
          collaboration.pairDriver(
            driver,
            collaboration.pairingCode,
            sessionId: policy?.sessionId,
          ),
          isTrue,
        );
        final task = controller.snapshot;
        expect(
          collaboration.confirm(
            driver,
            task.taskId!,
            task.revision - 1,
            context: policy?.identity,
          ),
          isFalse,
          reason: 'Old revision cannot train memory',
        );
        expect((state.ownerMemory as OwnerMemory).entries, isEmpty);
        clearVehicleSources();
        expect(
          collaboration.confirm(
            driver,
            task.taskId!,
            task.revision,
            context: policy?.identity,
          ),
          isTrue,
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        expect(controller.snapshot.phase, RepairPhase.completed);
        expect(controller.snapshot.result?.success, isTrue);
        expect(controller.snapshot.result?.simulated, isTrue);
        expect(
          (state.ownerMemory as OwnerMemory).entries.single.changes,
          expected,
        );
        expect(await tester.runAsync(() => file.exists()), isTrue);
        final reloaded = OwnerMemory(file: file);
        await tester.runAsync(() => reloaded.load());
        expect(reloaded.entries, hasLength(1));
        expect(reloaded.recall(phrase)?.changes, expected);
        cloud.online = false;
        state.cloudLink.online = false;
        state.ownerMemory = reloaded;
        final calls = cloud.generationCalls;
        state.input.text = '$phrase喔！';
        await tester.runAsync(
          () => HttpOverrides.runZoned(
            () async => state.submit(),
            createHttpClient: (_) => _Client(cloud),
          ),
        );
        await tester.pump();
        expect(controller.snapshot.patchSource, 'memory');
        expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
        expect(controller.snapshot.pending, expected);
        expect(
          cloud.generationCalls,
          calls,
          reason: 'Offline recall must make no cloud call',
        );
        expect(
          (state.actuator as MockCabinActuator).executeCount,
          1,
          reason: 'Recall proposes only; it does not auto-execute',
        );
        expect(
          find.text('車主記憶'),
          findsWidgets,
          reason: 'Memory source is visible in actual host widget',
        );

        // MEM-01 回歸：駕駛口令要用駕駛自己的原話學，不能覆寫上一句乘客的記憶。
        expect(controller.cancel(), isTrue);
        cloud.online = true;
        state.cloudLink.online = true;
        cloud.answer =
            '{"changes":{"mediaVolume":"decrease"},"clarification":null}';
        final driverResult = await tester.runAsync(
          () => HttpOverrides.runZoned(
            () => collaboration.driverRequest(
              driver,
              '我要講電話',
              sessionId: policy?.sessionId,
            ),
            createHttpClient: (_) => _Client(cloud),
          ),
        );
        expect(driverResult, 'executed');
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        expect(controller.snapshot.phase, RepairPhase.completed);
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        expect(
          reloaded.recall('我要講電話')?.changes,
          {CabinSetting.mediaVolume: RequestedChange.decrease},
          reason: 'MEM-01 fixed: driver-origin cloud phrase is learned under its own words',
        );
        expect(
          reloaded.recall(phrase)?.changes,
          expected,
          reason: 'MEM-01 fixed: earlier passenger phrase is not overwritten',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.binding.setSurfaceSize(null);
        HttpOverrides.global = previousOverride;
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('sense_in_balance/repair_speech'),
          null,
        );
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
