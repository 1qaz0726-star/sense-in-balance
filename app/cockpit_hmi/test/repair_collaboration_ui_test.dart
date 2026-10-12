import 'dart:async';
import 'dart:convert';

import 'package:cockpit_hmi/cockpit_design.dart';
import 'package:cockpit_hmi/main_repair_web.dart';
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
