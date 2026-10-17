import 'dart:async';
import 'dart:convert';

import 'package:cockpit_hmi/cabin_coordination_widgets.dart';
import 'package:cockpit_hmi/cockpit_design.dart';
import 'package:cockpit_hmi/cockpit_instruments.dart';
import 'package:cockpit_hmi/main_repair_web.dart';
import 'package:cockpit_hmi/repair_collaboration_widgets.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Map<String, dynamic> _context({
  String phase = 'clear',
  bool restricted = false,
  bool unsupported = false,
  int epoch = 4,
}) => {
  'cabin_session_id': 'cabin-ui',
  'profile_id': restricted ? 'fictional-cabin-b' : 'fictional-cabin-a',
  'profile_revision': 1,
  'attention_epoch': epoch,
  'profile': {
    'label': restricted ? '模擬座艙 B' : '模擬座艙 A',
    'supported': [if (!restricted) 'rearFan', 'mediaVolume', 'navVolume'],
    'readable': [if (!restricted) 'rearFan', 'mediaVolume', 'navVolume'],
    'fictional': true,
    'simulated': true,
  },
  'attention': {
    'phase': phase,
    'mode': phase == 'blocked' ? 'handoverRequested' : 'manual',
    'epoch': epoch,
    'simulated': true,
  },
  'capability': {
    'ready': !unsupported,
    'unsupported': {if (unsupported) 'rearFan': '本模擬座艙未提供後座風量控制介面'},
  },
  'requires_resume': phase == 'resume_required',
  'can_grant': phase != 'blocked',
  'can_confirm': phase == 'clear' && !unsupported,
  'can_resume_confirm': phase == 'resume_required' && !unsupported,
};

Map<String, dynamic> _task({
  bool fan = false,
  String phase = 'awaitingConfirmation',
}) => {
  'task_id': 'task-ui',
  'revision': 2,
  'phase': phase,
  'pending': {
    if (fan) 'rearFan': 'decrease',
    'mediaVolume': 'decrease',
    'navVolume': 'keep',
  },
  'clarification': null,
  'error': null,
  'result': null,
};

Map<String, dynamic> _status(
  Map context, {
  String role = 'driver',
  Map? task,
}) => {
  'type': 'repair_status',
  'schema': 2,
  'role': role,
  'cabin_context': context,
  'task': task ?? _task(),
  'collaboration': {
    'paired': role == 'driver',
    'driver_online': role == 'driver',
    'passenger_authorized': false,
  },
  'cabin_state': {'rearFan': null, 'mediaVolume': 5, 'navVolume': 5},
};

Map<String, dynamic> _completedTask(Map context) => {
  ..._task(phase: 'completed'),
  'result': {
    'success': true,
    'simulated': true,
    'state': {'rearFan': 3, 'mediaVolume': 4, 'navVolume': 5},
    'items': {
      'mediaVolume': {'before': 5, 'after': 4, 'success': true},
      'navVolume': {'before': 5, 'after': 5, 'success': true},
    },
    'execution_context': {
      'cabin_session_id': context['cabin_session_id'],
      'profile_id': context['profile_id'],
      'profile_revision': context['profile_revision'],
    },
  },
};

class _Sink implements WebSocketSink {
  final commands = <Map>[];
  @override
  void add(dynamic value) => commands.add(jsonDecode(value as String) as Map);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream stream) async {
    await for (final value in stream) {
      add(value);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
  @override
  Future<void> get done => Future.value();
}

class _Channel implements WebSocketChannel {
  final incoming = StreamController<dynamic>(sync: true);
  @override
  final _Sink sink = _Sink();
  @override
  Stream get stream => incoming.stream;
  @override
  Future<void> get ready => Future.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  void emit(Map value) => incoming.add(jsonEncode(value));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _panel(
  WidgetTester tester,
  Map context, {
  Map? task,
  ValueChanged<String>? onAction,
}) => tester.pumpWidget(
  MaterialApp(
    theme: CockpitStyle.theme,
    home: Scaffold(
      body: SingleChildScrollView(
        child: DriverCollaborationPanel(
          task: task ?? _task(),
          collaboration: const {},
          fresh: true,
          driver: true,
          commandPending: false,
          onPair: (_) {},
          onAction: onAction ?? (_) {},
          cabinContext: context,
        ),
      ),
    ),
  ),
);

void main() {
  for (final replacement in ['new task', 'new cabin session']) {
    testWidgets('pending result speech cannot outlive a $replacement', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 1100);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final voices = Completer<List<Map<String, dynamic>>>();
      final calls = <String>[];
      const tts = MethodChannel('flutter_tts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(tts, (call) async {
            calls.add(call.method);
            return call.method == 'getVoices' ? voices.future : 1;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(tts, null),
      );
      final channel = _Channel();
      await tester.pumpWidget(
        MaterialApp(
          theme: CockpitStyle.theme,
          home: RepairMonitor(
            url: Uri.parse('ws://cabin/repair'),
            channelFactory: (_) => channel,
          ),
        ),
      );
      await tester.pump();
      final context = _context(restricted: true);
      channel.emit(_status(context, task: _completedTask(context)));
      await tester.pump();
      await tester.ensureVisible(find.text('播報結果'));
      await tester.tap(find.text('播報結果'));
      await tester.pump();
      expect(calls, contains('getVoices'));
      final stopsBefore = calls.where((call) => call == 'stop').length;
      if (replacement == 'new task') {
        final nextTask = _task()..['task_id'] = 'different-task';
        channel.emit(_status(context, task: nextTask));
      } else {
        final nextContext = _context(restricted: true)
          ..['cabin_session_id'] = 'different-session';
        channel.emit(_status(nextContext, task: _completedTask(nextContext)));
      }
      await tester.pump();
      voices.complete([
        {
          'name': 'local',
          'locale': 'zh-TW',
          'network_required': '0',
          'features': '',
        },
      ]);
      await tester.pump();
      await tester.pump();
      expect(
        calls.where((call) => call == 'stop').length,
        greaterThan(stopsBefore),
      );
      expect(calls, isNot(contains('speak')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      unawaited(channel.incoming.close());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('disconnect stops an already started result narration', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 1100);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <String>[];
    const tts = MethodChannel('flutter_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(tts, (call) async {
          calls.add(call.method);
          if (call.method == 'getVoices') {
            return [
              {
                'name': 'local',
                'locale': 'zh-TW',
                'network_required': '0',
                'features': '',
              },
            ];
          }
          return 1;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(tts, null),
    );
    final channel = _Channel();
    await tester.pumpWidget(
      MaterialApp(
        theme: CockpitStyle.theme,
        home: RepairMonitor(
          url: Uri.parse('ws://cabin/repair'),
          channelFactory: (_) => channel,
        ),
      ),
    );
    await tester.pump();
    final context = _context(restricted: true);
    channel.emit(_status(context, task: _completedTask(context)));
    await tester.pump();
    await tester.ensureVisible(find.text('播報結果'));
    await tester.tap(find.text('播報結果'));
    await tester.pump();
    await tester.pump();
    expect(calls, contains('speak'));
    final stopsBefore = calls.where((call) => call == 'stop').length;
    unawaited(channel.incoming.close());
    await tester.pump();
    expect(
      calls.where((call) => call == 'stop').length,
      greaterThan(stopsBefore),
    );
    expect(find.text('等待重新連線'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'priority attention removes nonurgent driver controls and details',
    (tester) async {
      await _panel(tester, _context(phase: 'blocked'));
      expect(find.text('接管提醒（模擬）'), findsOneWidget);
      expect(find.text('乘客需求已保留，暫不需要處理。'), findsOneWidget);
      expect(find.byKey(const ValueKey('driver_confirm')), findsNothing);
      expect(find.byKey(const ValueKey('driver_grant')), findsNothing);
      expect(find.text('音樂音量'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('駕駛確認頁：一句話＋確認鍵，取消收在「更多」', (tester) async {
    final actions = <String>[];
    await _panel(tester, _context(), onAction: actions.add);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('driver_one_line'))).data,
      '音樂小一格，導航不變',
    );
    expect(find.byKey(const ValueKey('driver_confirm')), findsOneWidget);
    expect(find.byKey(const ValueKey('driver_cancel')), findsNothing);
    expect(find.text('降低一格'), findsNothing, reason: '明細預設收起');
    await tester.ensureVisible(find.byKey(const ValueKey('driver_more')));
    await tester.tap(find.byKey(const ValueKey('driver_more')));
    await tester.pump();
    expect(find.byKey(const ValueKey('driver_cancel')), findsOneWidget);
    expect(actions, isEmpty);
  });

  testWidgets('resume is one explicit action using latest candidate', (
    tester,
  ) async {
    final actions = <String>[];
    await _panel(
      tester,
      _context(phase: 'resume_required'),
      onAction: actions.add,
    );
    expect(actions, isEmpty);
    expect(find.text('繼續並確認最新 2 項'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('driver_confirm')));
    await tester.tap(find.byKey(const ValueKey('driver_confirm')));
    expect(actions, ['resume_confirm']);
  });

  testWidgets('unsupported retained demand cannot be confirmed by driver', (
    tester,
  ) async {
    await _panel(
      tester,
      _context(restricted: true, unsupported: true),
      task: _task(fan: true),
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('driver_confirm')),
    );
    expect(button.onPressed, isNull);
    // 一句話摘要直接講受限；明細收起，按「看明細」才出現逐項說明。
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('driver_one_line'))).data,
      contains('後座風此車不支援'),
    );
    expect(find.text('此車受限 · 未送出'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('driver_details_toggle')),
    );
    await tester.tap(find.byKey(const ValueKey('driver_details_toggle')));
    await tester.pump();
    expect(find.text('此車受限 · 未送出'), findsOneWidget);
    expect(find.text('先處理受限項目'), findsOneWidget);
  });

  testWidgets(
    'passenger must explicitly remove restricted item with current lease',
    (tester) async {
      final changes = <RequestedChange>[];
      Future<void> render(bool canRevise) => tester.pumpWidget(
        MaterialApp(
          theme: CockpitStyle.theme,
          home: Scaffold(
            body: PassengerCandidateEditor(
              pending: const {
                CabinSetting.rearFan: RequestedChange.decrease,
                CabinSetting.mediaVolume: RequestedChange.decrease,
              },
              unsupported: const {'rearFan': '本模擬座艙未提供後座風量控制介面'},
              canRevise: canRevise,
              onPatch: (_, change) => changes.add(change),
            ),
          ),
        ),
      );
      await render(false);
      final remove = find.byKey(const ValueKey('passenger_remove_rearFan'));
      expect(tester.widget<TextButton>(remove).onPressed, isNull);
      expect(changes, isEmpty);
      await render(true);
      await tester.tap(remove);
      expect(changes, [RequestedChange.remove]);
    },
  );

  test(
    'B completion requires genuine supported item ACK and matching execution identity',
    () {
      final context = _context(restricted: true);
      final task = _task(phase: 'completed');
      final result = <String, dynamic>{
        'success': true,
        'simulated': true,
        'state': {'rearFan': 3, 'mediaVolume': 4, 'navVolume': 5},
        'items': {
          'mediaVolume': {'before': 5, 'after': 4, 'success': true},
          'navVolume': {'before': 5, 'after': 5, 'success': true},
        },
        'execution_context': {
          'cabin_session_id': 'cabin-ui',
          'profile_id': 'fictional-cabin-b',
          'profile_revision': 1,
        },
      };
      task['result'] = result;
      final state = completedSimulatedCabinState(task, cabinContext: context);
      expect(state, {'rearFan': null, 'mediaVolume': 4, 'navVolume': 5});
      (result['items'] as Map).remove('navVolume');
      expect(completedSimulatedCabinState(task, cabinContext: context), isNull);
      result['items'] = {
        'mediaVolume': {'before': 5, 'after': 4, 'success': true},
        'navVolume': {'before': 5, 'after': 5, 'success': true},
      };
      (result['execution_context'] as Map)['cabin_session_id'] = 'old-session';
      expect(completedSimulatedCabinState(task, cabinContext: context), isNull);
    },
  );

  testWidgets('attention strip has identical geometry for all states', (
    tester,
  ) async {
    Size? baseline;
    for (final phase in ['clear', 'blocked', 'resume_required']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              child: CabinAttentionStrip(
                contextData: _context(phase: phase),
                onViewSummary: () {},
              ),
            ),
          ),
        ),
      );
      final size = tester.getSize(
        find.byKey(const ValueKey('cabin_attention_strip')),
      );
      baseline ??= size;
      expect(size, baseline);
      expect(size.height, 54);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'schema2 pair and resume commands bind session and all context versions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 1100);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final channel = _Channel();
      await tester.pumpWidget(
        MaterialApp(
          theme: CockpitStyle.theme,
          home: RepairMonitor(
            url: Uri.parse('ws://cabin/repair'),
            channelFactory: (_) => channel,
          ),
        ),
      );
      await tester.pump();
      channel.emit(_status(_context(restricted: true), role: 'observer'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('driver_pairing_code')),
        '123456',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('driver_pair')));
      await tester.pump();
      final pair = channel.sink.commands.last;
      expect(pair['cabin_session_id'], 'cabin-ui');
      expect(pair.containsKey('profile_id'), isFalse);
      channel.emit({
        'type': 'repair_reply',
        'command_id': pair['command_id'],
        'accepted': true,
      });
      channel.emit(
        _status(_context(phase: 'resume_required', restricted: true)),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('driver_confirm')));
      await tester.tap(find.byKey(const ValueKey('driver_confirm')));
      await tester.pump();
      final resume = channel.sink.commands.last;
      expect(resume['action'], 'resume_confirm');
      expect(resume['cabin_session_id'], 'cabin-ui');
      expect(resume['profile_id'], 'fictional-cabin-b');
      expect(resume['profile_revision'], 1);
      expect(resume['attention_epoch'], 4);
      expect(resume['revision'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      unawaited(channel.incoming.close());
    },
  );

  testWidgets(
    'priority heartbeat does not repeatedly switch views and release never auto-resumes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 1100);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final channel = _Channel();
      await tester.pumpWidget(
        MaterialApp(
          theme: CockpitStyle.theme,
          home: RepairMonitor(
            url: Uri.parse('ws://cabin/repair'),
            channelFactory: (_) => channel,
          ),
        ),
      );
      await tester.pump();
      channel.emit(_status(_context(phase: 'blocked')));
      await tester.pump();
      expect(find.byType(CockpitInstrumentPanel), findsOneWidget);
      final initialRect = tester.getRect(find.byType(CockpitInstrumentPanel));
      await tester.tap(find.text('需求摘要'));
      await tester.pump();
      for (var i = 0; i < 10; ++i) {
        channel.emit(_status(_context(phase: 'blocked')));
        await tester.pump();
      }
      expect(find.byType(DriverCollaborationPanel), findsOneWidget);
      await tester.tap(find.text('行車儀表'));
      await tester.pump();
      channel.emit(_status(_context(phase: 'resume_required', epoch: 5)));
      await tester.pump();
      expect(find.byType(CockpitInstrumentPanel), findsOneWidget);
      expect(tester.getRect(find.byType(CockpitInstrumentPanel)), initialRect);
      expect(
        channel.sink.commands.where(
          (m) => m['action'] == 'confirm' || m['action'] == 'resume_confirm',
        ),
        isEmpty,
      );
      expect(find.text('查看摘要'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      unawaited(channel.incoming.close());
    },
  );
}
