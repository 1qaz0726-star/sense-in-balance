import 'dart:async';
import 'dart:convert';

import 'package:cockpit_hmi/cockpit_design.dart';
import 'package:cockpit_hmi/main_repair_web.dart';
import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_collaboration_widgets.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Map<String, dynamic> _status({
  String role = 'observer',
  int revision = 1,
  String phase = 'awaitingConfirmation',
  bool authorized = false,
  bool removedFan = false,
}) => {
  'type': 'repair_status',
  'schema': 1,
  'role': role,
  'model': 'Qwen 2.5 1.5B · 電腦本地推論',
  'collaboration': {
    'paired': role == 'driver',
    'driver_online': role == 'driver',
    'passenger_authorized': authorized,
    'authorization_task_id': authorized ? 'repair_ui' : null,
    'authorization_expires_at': authorized
        ? DateTime.now()
              .add(const Duration(seconds: 120))
              .millisecondsSinceEpoch
        : null,
  },
  'cabin_state': {'rearFan': 3, 'mediaVolume': 5, 'navVolume': 5},
  'task': {
    'task_id': 'repair_ui',
    'revision': revision,
    'phase': phase,
    'pending': {
      if (!removedFan) 'rearFan': 'decrease',
      'mediaVolume': 'decrease',
      'navVolume': 'keep',
    },
    'clarification': null,
    'error': null,
    'result': phase == 'completed'
        ? {
            'success': true,
            'simulated': true,
            'message': '模擬設定已更新',
            'state': {'rearFan': 3, 'mediaVolume': 4, 'navVolume': 5},
          }
        : null,
  },
};

class _TestSink implements WebSocketSink {
  final commands = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  void add(dynamic data) {
    if (closed) throw StateError('closed');
    commands.add(Map<String, dynamic>.from(jsonDecode(data as String) as Map));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  Future<void> get done => Future<void>.value();
}

class _TestChannel implements WebSocketChannel {
  final incoming = StreamController<dynamic>(sync: true);
  @override
  final _TestSink sink = _TestSink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready => Future<void>.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  void emit(Map<String, dynamic> message) => incoming.add(jsonEncode(message));
  void reply(Map<String, dynamic> command, bool accepted, [String? error]) =>
      emit({
        'type': 'repair_reply',
        'command_id': command['command_id'],
        'accepted': accepted,
        'error': error,
      });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('passenger edits are disabled without the current driver lease', (
    tester,
  ) async {
    final changes = <(CabinSetting, RequestedChange)>[];
    Future<void> render(bool authorized) => tester.pumpWidget(
      MaterialApp(
        theme: CockpitStyle.theme,
        home: Scaffold(
          body: PassengerCandidateEditor(
            pending: const {CabinSetting.mediaVolume: RequestedChange.decrease},
            canRevise: authorized,
            onPatch: (setting, change) => changes.add((setting, change)),
          ),
        ),
      ),
    );
    await render(false);
    final menu = find.byKey(const ValueKey('passenger_edit_mediaVolume'));
    expect(
      tester.widget<PopupMenuButton<RequestedChange>>(menu).enabled,
      isFalse,
    );
    expect(changes, isEmpty);
    expect(find.text('確認套用（車控模擬）'), findsNothing);
    await render(true);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('維持原值'));
    await tester.pumpAndSettle();
    expect(changes, [(CabinSetting.mediaVolume, RequestedChange.keep)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'passenger sees acknowledged items while editing the remaining unresolved candidate',
    (tester) async {
      const question = '導航要提高還是維持原值？';
      var parseCount = 0;
      var executeCount = 0;
      final controller = RepairController(
        parser: (_, _) async => ++parseCount == 1
            ? IntentPatch(
                changes: {
                  CabinSetting.mediaVolume: RequestedChange.decrease,
                  CabinSetting.rearFan: RequestedChange.decrease,
                },
              )
            : IntentPatch(changes: {}, clarification: question),
        actuator: (_, _) async {
          executeCount++;
          return ExecutionReceipt(
            success: false,
            simulated: true,
            message: '音樂完成，風量尚未執行。',
            state: {CabinSetting.mediaVolume: 4, CabinSetting.rearFan: 3},
            items: {
              CabinSetting.mediaVolume: {
                'before': 5,
                'after': 4,
                'action': 'decrease',
                'success': true,
              },
              CabinSetting.rearFan: {
                'before': 3,
                'after': 3,
                'action': 'decrease',
                'success': false,
              },
            },
          );
        },
      );
      final collaboration = RepairCollaboration(controller);
      try {
        await collaboration.newTask('音樂與風量都調小');
        final driver = Object();
        expect(
          collaboration.pairDriver(driver, collaboration.pairingCode),
          isTrue,
        );
        var task = controller.snapshot;
        expect(
          collaboration.confirm(driver, task.taskId!, task.revision),
          isTrue,
        );
        await tester.pump();
        task = controller.snapshot;
        expect(task.phase, RepairPhase.failed);
        expect(
          collaboration.grant(driver, task.taskId!, task.revision),
          isTrue,
        );
        await collaboration.revise('還有導航');
        await tester.pumpWidget(
          MaterialApp(
            theme: CockpitStyle.theme,
            home: Scaffold(
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => Column(
                  children: [
                    if (controller.snapshot.clarification != null)
                      Text(controller.snapshot.clarification!),
                    PassengerCandidateEditor(
                      pending: controller.snapshot.pending,
                      acknowledgedItems:
                          controller.snapshot.result?.items ?? const {},
                      canRevise: collaboration.canRevise,
                      onPatch: (setting, change) =>
                          collaboration.directPatch(setting, change),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text('先前已完成（5至4）'), findsOneWidget);
        expect(
          controller.snapshot.pending.containsKey(CabinSetting.mediaVolume),
          isFalse,
        );
        final remaining = find.byKey(const ValueKey('passenger_edit_rearFan'));
        expect(
          tester.widget<PopupMenuButton<RequestedChange>>(remaining).enabled,
          isTrue,
        );
        await tester.tap(remaining);
        await tester.pumpAndSettle();
        await tester.tap(find.text('維持原值'));
        await tester.pumpAndSettle();
        expect(
          controller.snapshot.pending[CabinSetting.rearFan],
          RequestedChange.keep,
        );
        expect(find.text(question), findsOneWidget);
        expect(controller.snapshot.phase, RepairPhase.awaitingClarification);
        expect(find.text('先前已完成（5至4）'), findsOneWidget);
        expect(find.byKey(const ValueKey('driver_confirm')), findsNothing);
        task = controller.snapshot;
        expect(await controller.confirm(task.taskId!, task.revision), isFalse);
        expect(executeCount, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        collaboration.dispose();
        controller.dispose();
      }
    },
  );

  testWidgets(
    'driver controls require role, current candidate and fresh status',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final actions = <String>[];
      Future<void> render({
        required bool fresh,
        required bool driver,
        String phase = 'awaitingConfirmation',
      }) {
        final frame = _status(
          role: driver ? 'driver' : 'observer',
          phase: phase,
        );
        return tester.pumpWidget(
          MaterialApp(
            theme: CockpitStyle.theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: DriverCollaborationPanel(
                  task: frame['task'] as Map,
                  collaboration: frame['collaboration'] as Map,
                  fresh: fresh,
                  driver: driver,
                  commandPending: false,
                  onPair: (_) {},
                  onAction: actions.add,
                ),
              ),
            ),
          ),
        );
      }

      await render(fresh: true, driver: false);
      expect(find.byKey(const ValueKey('driver_confirm')), findsNothing);
      await render(fresh: true, driver: true, phase: 'awaitingClarification');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('driver_confirm')))
            .onPressed,
        isNull,
      );
      await render(fresh: true, driver: true);
      await tester.tap(find.byKey(const ValueKey('driver_confirm')));
      expect(actions, ['confirm']);
      expect(find.text('模擬座艙已更新'), findsNothing);
      await render(fresh: false, driver: true, phase: 'completed');
      expect(find.byKey(const ValueKey('driver_confirm')), findsNothing);
      expect(find.text('模擬座艙已更新'), findsNothing);
      expect(find.text('等待重新連線'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'driver receipts show final values without obsolete actions or false completion',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final receipt = {
        'success': true,
        'simulated': true,
        'state': {'rearFan': 3, 'mediaVolume': 4, 'navVolume': 5},
        'items': {
          'mediaVolume': {
            'before': 5,
            'after': 4,
            'action': 'decrease',
            'success': true,
          },
          'navVolume': {
            'before': 5,
            'after': 5,
            'action': 'keep',
            'success': true,
          },
        },
      };
      Future<void> render(String phase, {Map? result, bool fresh = true}) {
        final frame = _status(role: 'driver', phase: phase);
        (frame['task'] as Map)['result'] = result;
        return tester.pumpWidget(
          MaterialApp(
            theme: CockpitStyle.theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: DriverCollaborationPanel(
                  task: frame['task'] as Map,
                  collaboration: frame['collaboration'] as Map,
                  fresh: fresh,
                  driver: true,
                  commandPending: false,
                  onPair: (_) {},
                  onAction: (_) {},
                ),
              ),
            ),
          ),
        );
      }

      await render('completed', result: receipt);
      expect(find.text('模擬座艙已更新'), findsOneWidget);
      for (final entry in {
        'rearFan': '3',
        'mediaVolume': '4',
        'navVolume': '5',
      }.entries) {
        final value = find.byKey(ValueKey('driver_final_${entry.key}'));
        expect(tester.widget<Text>(value).data, entry.value);
        expect(tester.getBottomRight(value).dy, lessThan(844));
      }
      expect(find.text('5 → 4 · 已回報'), findsOneWidget);
      expect(find.text('未提供逐項回報'), findsOneWidget);
      for (final action in ['grant', 'revoke', 'confirm', 'cancel']) {
        expect(find.byKey(ValueKey('driver_$action')), findsNothing);
      }
      final legacyReceipt = Map<String, dynamic>.of(receipt)..remove('items');
      await render('completed', result: legacyReceipt);
      expect(find.text('未提供逐項回報'), findsNWidgets(3));
      expect(find.text('未列入這次調整'), findsNothing);
      await render(
        'completed',
        result: {
          ...receipt,
          'state': {'rearFan': 3, 'mediaVolume': 4},
        },
      );
      expect(find.text('執行回報待核對'), findsOneWidget);
      for (final setting in ['rearFan', 'mediaVolume', 'navVolume']) {
        expect(find.byKey(ValueKey('driver_final_$setting')), findsNothing);
      }
      for (final phase in [
        'parsing',
        'executing',
        'awaitingClarification',
        'indeterminate',
        'failed',
      ]) {
        await render(phase, result: receipt);
        expect(find.text('模擬座艙已更新'), findsNothing);
        expect(
          find.byKey(const ValueKey('driver_final_mediaVolume')),
          findsNothing,
        );
      }
      await render('completed');
      expect(find.text('執行回報待核對'), findsOneWidget);
      expect(find.text('模擬座艙已更新'), findsNothing);
      await render('completed', result: receipt, fresh: false);
      expect(
        find.byKey(const ValueKey('driver_final_navVolume')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial receipts remain separate from the next candidate', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final frame = _status(role: 'driver', phase: 'failed');
    final task = frame['task'] as Map;
    task['pending'] = {'mediaVolume': 'decrease'};
    task['result'] = {
      'success': false,
      'simulated': true,
      'state': {'rearFan': 2, 'mediaVolume': 5, 'navVolume': 5},
      'items': {
        'rearFan': {'before': 3, 'after': 2, 'success': true},
        'mediaVolume': {'before': 5, 'after': 5, 'success': false},
      },
    };
    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        theme: CockpitStyle.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: DriverCollaborationPanel(
              task: task,
              collaboration: frame['collaboration'] as Map,
              fresh: true,
              driver: true,
              commandPending: false,
              onPair: (_) {},
              onAction: (_) {},
            ),
          ),
        ),
      ),
    );
    await render();
    expect(find.text('部分執行回報 · 未完成項仍待處理'), findsOneWidget);
    expect(find.text('3 → 2 · 已完成'), findsOneWidget);
    expect(find.text('5 → 5 · 未完成'), findsOneWidget);
    expect(find.text('模擬座艙已更新'), findsNothing);
    task['phase'] = 'awaitingConfirmation';
    await render();
    expect(find.text('先前執行回報 · 本次僅確認待執行項'), findsOneWidget);
    expect(find.text('模擬座艙已更新'), findsNothing);
    task['phase'] = 'cancelled';
    task['pending'] = <String, dynamic>{};
    await render();
    expect(find.text('已取消未執行需求；已完成設定不會還原。'), findsOneWidget);
    expect(find.text('3 → 2 · 已完成'), findsOneWidget);
    expect(find.text('5 → 5 · 未完成'), findsNothing);
    expect(find.byKey(const ValueKey('driver_confirm')), findsNothing);
    expect(find.text('模擬座艙已更新'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone pairing dismisses focus and returns the summary and receipt to the top',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      final channel = _TestChannel();
      addTearDown(() => unawaited(channel.incoming.close()));
      await tester.pumpWidget(
        MaterialApp(
          theme: CockpitStyle.theme,
          home: RepairMonitor(
            url: Uri.parse('ws://local/repair'),
            channelFactory: (_) => channel,
          ),
        ),
      );
      await tester.pump();
      channel.emit(_status());
      await tester.pump();
      final input = find.byKey(const ValueKey('driver_pairing_code'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '123456');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump();
      final scrollFinder = find.byKey(const ValueKey('monitor_view_1'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      expect(controller.offset, greaterThan(0));
      final focus = tester.widget<TextField>(input).focusNode!;
      expect(focus.hasFocus, isTrue);
      await tester.ensureVisible(find.byKey(const ValueKey('driver_pair')));
      await tester.tap(find.byKey(const ValueKey('driver_pair')));
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      final pair = channel.sink.commands.last;
      expect(pair['action'], 'pair_driver');
      tester.view.resetViewInsets();
      channel.reply(pair, true);
      channel.emit(_status(role: 'driver'));
      await tester.pump();
      await tester.pump();
      expect(controller.offset, 0);
      expect(find.text('請看需求摘要'), findsOneWidget);
      await tester.drag(scrollFinder, const Offset(0, -220));
      await tester.pump();
      expect(controller.offset, greaterThan(0));
      channel.emit(
        _status(role: 'driver', phase: 'completed', removedFan: true),
      );
      await tester.pump();
      await tester.pump();
      expect(controller.offset, 0);
      expect(find.text('模擬座艙已更新'), findsOneWidget);
      expect(find.text('座艙設定'), findsNothing);
      expect(find.byKey(const ValueKey('driver_confirm')), findsNothing);
      for (final setting in ['rearFan', 'mediaVolume', 'navVolume']) {
        final value = find.byKey(ValueKey('driver_final_$setting'));
        expect(tester.getBottomRight(value).dy, lessThan(844));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'monitor pairs, versions commands and waits for an execution receipt',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 1100);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final channel = _TestChannel();
      addTearDown(() async {
        unawaited(channel.incoming.close());
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: CockpitStyle.theme,
          home: RepairMonitor(
            url: Uri.parse('ws://local/repair'),
            channelFactory: (_) => channel,
          ),
        ),
      );
      await tester.pump();
      channel.emit(_status());
      await tester.pump();
      expect(find.text('需求摘要'), findsOneWidget);
      expect(find.byKey(const ValueKey('driver_confirm')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('driver_pairing_code')),
        '123456',
      );
      await tester.pump();
      expect(
        tester
            .widget<DriverCollaborationPanel>(
              find.byType(DriverCollaborationPanel),
            )
            .fresh,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('driver_pairing_code')),
            )
            .controller!
            .text,
        '123456',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('driver_pair')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('driver_pair')));
      await tester.pump();
      final pair = channel.sink.commands.last;
      expect(pair['action'], 'pair_driver');
      expect(pair['pairing_code'], '123456');
      expect(pair.containsKey('task_id'), isFalse);
      channel.reply(pair, true);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('driver_grant')),
        findsNothing,
        reason:
            'An accepted pair reply alone is not an authoritative driver status.',
      );
      channel.emit(_status(role: 'driver'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('driver_grant')));
      await tester.pump();
      final grant = channel.sink.commands.last;
      expect(grant['action'], 'grant');
      expect(grant['task_id'], 'repair_ui');
      expect(grant['revision'], 1);
      channel.reply(grant, true);
      channel.emit(
        _status(
          role: 'driver',
          revision: 2,
          authorized: true,
          removedFan: true,
        ),
      );
      await tester.pump();
      expect(find.text('這次只改：後座風量；其餘保留'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('driver_confirm')));
      await tester.pump();
      final rejected = channel.sink.commands.last;
      expect(rejected['revision'], 2);
      channel.reply(rejected, false, '需求版本已更新，請重新確認。');
      await tester.pump();
      expect(find.text('需求版本已更新，請重新確認。'), findsOneWidget);
      expect(find.text('模擬座艙已更新'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('driver_confirm')));
      await tester.pump();
      final confirmed = channel.sink.commands.last;
      expect(confirmed['command_id'], isNot(rejected['command_id']));
      channel.reply(confirmed, true);
      await tester.pump();
      expect(find.text('模擬座艙已更新'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('driver_confirm')))
            .onPressed,
        isNull,
      );
      channel.emit(
        _status(
          role: 'driver',
          revision: 2,
          phase: 'completed',
          removedFan: true,
        ),
      );
      await tester.pump();
      expect(find.text('模擬座艙已更新'), findsOneWidget);
      unawaited(channel.incoming.close());
      await tester.pump();
      expect(find.text('模擬座艙已更新'), findsNothing);
      expect(find.text('等待重新連線'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
