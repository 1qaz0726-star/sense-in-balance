import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/hub.dart';
import 'package:cockpit_hmi/protocol.dart';
import 'package:cockpit_hmi/repair_hub.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('只有配對駕駛能授權和確認，版本嚴格，命令去重不雙執行', () async {
    final mock = MockCabinActuator();
    final controller = RepairController(
      parser: (_, _) async => IntentPatch(
        changes: {
          CabinSetting.rearFan: RequestedChange.decrease,
          CabinSetting.mediaVolume: RequestedChange.decrease,
        },
      ),
      actuator: mock.call,
    );
    final collaboration = RepairCollaboration(controller);
    final hub = RepairHub(
      controller,
      modelStatus: () => '模型測試替身',
      asset: (_) async => null,
      collaboration: collaboration,
    );
    final sockets = <WebSocket>[];
    final subs = <StreamSubscription>[];
    addTearDown(() async {
      for (final sub in subs) {
        await sub.cancel();
      }
      for (final socket in sockets) {
        await socket.close();
      }
      await hub.stop();
      collaboration.dispose();
      controller.dispose();
    });
    await hub.start();
    Future<(WebSocket, List<Map>)> connect() async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${RepairHub.port}/repair',
      );
      sockets.add(socket);
      final frames = <Map>[];
      subs.add(socket.listen((raw) => frames.add(jsonDecode(raw) as Map)));
      return (socket, frames);
    }

    final (driver, driverFrames) = await connect();
    final (observer, observerFrames) = await connect();
    Future<void> until(bool Function() predicate) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!predicate()) {
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('等不到協作回覆');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Future<Map> command(
      WebSocket socket,
      List<Map> frames,
      String id,
      String action, {
      Map<String, dynamic> extra = const {},
    }) async {
      final previous = frames
          .where((f) => f['type'] == 'repair_reply' && f['command_id'] == id)
          .length;
      socket.add(
        jsonEncode({
          'type': 'repair_command',
          'command_id': id,
          'action': action,
          ...extra,
        }),
      );
      await until(
        () =>
            frames
                .where(
                  (f) => f['type'] == 'repair_reply' && f['command_id'] == id,
                )
                .length >
            previous,
      );
      return frames.lastWhere(
        (f) => f['type'] == 'repair_reply' && f['command_id'] == id,
      );
    }

    await collaboration.newTask('需求');
    final initial = controller.snapshot;
    Map<String, dynamic> version(RepairSnapshot s) => {
      'task_id': s.taskId,
      'revision': s.revision,
    };
    expect(
      (await command(
        observer,
        observerFrames,
        'no-confirm',
        'confirm',
        extra: version(initial),
      ))['accepted'],
      isFalse,
    );
    expect(
      (await command(
        driver,
        driverFrames,
        'pair',
        'pair_driver',
        extra: {'pairing_code': collaboration.pairingCode},
      ))['accepted'],
      isTrue,
    );
    await until(() => driverFrames.any((f) => f['role'] == 'driver'));
    expect(
      observerFrames
          .where((f) => f['type'] == 'repair_status')
          .every((f) => f['role'] == 'observer'),
      isTrue,
    );
    expect(
      driverFrames
          .where((f) => f['type'] == 'repair_status')
          .every(
            (f) => !(f['collaboration'] as Map).containsKey('pairing_code'),
          ),
      isTrue,
    );
    expect(
      (await command(
        driver,
        driverFrames,
        'bad-field',
        'grant',
        extra: {...version(initial), 'execute': true},
      ))['accepted'],
      isFalse,
    );
    expect(
      (await command(
        driver,
        driverFrames,
        'grant',
        'grant',
        extra: version(initial),
      ))['accepted'],
      isTrue,
    );
    expect(
      collaboration.directPatch(CabinSetting.rearFan, RequestedChange.remove),
      isTrue,
    );
    final revised = controller.snapshot;
    expect(
      (await command(
        driver,
        driverFrames,
        'old-confirm',
        'confirm',
        extra: version(initial),
      ))['accepted'],
      isFalse,
    );
    expect(
      (await command(
        observer,
        observerFrames,
        'no-revoke',
        'revoke',
        extra: version(revised),
      ))['accepted'],
      isFalse,
    );
    expect(
      (await command(
        driver,
        driverFrames,
        'apply',
        'confirm',
        extra: version(revised),
      ))['accepted'],
      isTrue,
    );
    expect(
      (await command(
        driver,
        driverFrames,
        'apply',
        'confirm',
        extra: version(revised),
      ))['accepted'],
      isTrue,
    );
    expect(
      (await command(
        driver,
        driverFrames,
        'apply',
        'cancel',
        extra: version(revised),
      ))['accepted'],
      isFalse,
    );
    await until(() => controller.snapshot.phase == RepairPhase.completed);
    expect(mock.executeCount, 1);
    expect(mock.state[CabinSetting.mediaVolume], 4);
    expect(collaboration.canRevise, isFalse);
  });

  test('駕駛socket關閉撤權，未完成的乘客解析不能復活', () async {
    var calls = 0;
    final late = Completer<IntentPatch>();
    final mock = MockCabinActuator();
    final controller = RepairController(
      parser: (_, _) => ++calls == 1
          ? Future.value(
              IntentPatch(
                changes: {CabinSetting.mediaVolume: RequestedChange.decrease},
              ),
            )
          : late.future,
      actuator: mock.call,
    );
    final collaboration = RepairCollaboration(controller);
    final hub = RepairHub(
      controller,
      modelStatus: () => '測試替身',
      asset: (_) async => null,
      collaboration: collaboration,
    );
    StreamSubscription? sub;
    WebSocket? socket;
    Future<bool>? parsing;
    addTearDown(() async {
      if (!late.isCompleted) {
        late.complete(
          IntentPatch(
            changes: {CabinSetting.mediaVolume: RequestedChange.increase},
          ),
        );
      }
      if (parsing != null) await parsing;
      await sub?.cancel();
      await socket?.close();
      await hub.stop();
      collaboration.dispose();
      controller.dispose();
    });
    await hub.start();
    await collaboration.newTask('初始需求');
    socket = await WebSocket.connect('ws://127.0.0.1:${RepairHub.port}/repair');
    final replies = <Map>[];
    sub = socket.listen((raw) {
      final value = jsonDecode(raw) as Map;
      if (value['type'] == 'repair_reply') replies.add(value);
    });
    Future<void> until(bool Function() p) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!p()) {
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('權限狀態逾時');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    socket.add(
      jsonEncode({
        'type': 'repair_command',
        'command_id': 'pair',
        'action': 'pair_driver',
        'pairing_code': collaboration.pairingCode,
      }),
    );
    await until(
      () => replies.any(
        (r) => r['command_id'] == 'pair' && r['accepted'] == true,
      ),
    );
    final before = controller.snapshot;
    socket.add(
      jsonEncode({
        'type': 'repair_command',
        'command_id': 'grant',
        'action': 'grant',
        'task_id': before.taskId,
        'revision': before.revision,
      }),
    );
    await until(() => collaboration.canRevise);
    parsing = collaboration.revise('改成提高');
    await socket.close();
    await until(() => !collaboration.driverOnline);
    late.complete(
      IntentPatch(
        changes: {CabinSetting.mediaVolume: RequestedChange.increase},
      ),
    );
    expect(await parsing, isFalse);
    expect(controller.snapshot.pending, before.pending);
    expect(mock.executeCount, 0);
  });

  test('主機尚在啟動就離開，不會復活或占用雙屏埠', () async {
    RepairController makeController() => RepairController(
      parser: (_, _) async => IntentPatch(
        changes: {CabinSetting.mediaVolume: RequestedChange.decrease},
      ),
      actuator: MockCabinActuator().call,
    );
    RepairHub makeHub(RepairController c) =>
        RepairHub(c, modelStatus: () => '測試替身', asset: (_) async => null);
    final controller = makeController();
    final hub = makeHub(controller);
    final starting = hub.start();
    await hub.stop();
    controller.dispose();
    await starting;
    final replacementController = makeController();
    final replacement = makeHub(replacementController);
    addTearDown(() async {
      await replacement.stop();
      replacementController.dispose();
    });
    await replacement.start();
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${RepairHub.port}/repair',
    );
    final frame = jsonDecode(await socket.first);
    expect(frame['task']['phase'], 'idle');
    await socket.close();
  });

  test('第二屏同步的是主機任務與ACK，不可透過只讀連線執行車控', () async {
    final mock = MockCabinActuator();
    final controller = RepairController(
      parser: (text, task) async => IntentPatch(
        changes: text == '取消風量'
            ? {CabinSetting.rearFan: RequestedChange.remove}
            : {
                CabinSetting.rearFan: RequestedChange.decrease,
                CabinSetting.mediaVolume: RequestedChange.decrease,
                CabinSetting.navVolume: RequestedChange.keep,
              },
      ),
      actuator: mock.call,
    );
    final hub = RepairHub(
      controller,
      modelStatus: () => '測試替身，非Qwen',
      cabinState: () => {
        for (final entry in mock.state.entries) entry.key.name: entry.value,
      },
      asset: (p) async =>
          p == 'index.html' ? utf8.encode('<html>read only</html>') : null,
    );
    addTearDown(() async {
      await hub.stop();
      controller.dispose();
    });
    await hub.start();
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${RepairHub.port}/repair',
    );
    final frames = <Map<String, dynamic>>[];
    final sub = socket.listen(
      (m) => frames.add(Map<String, dynamic>.from(jsonDecode(m))),
    );
    addTearDown(() async {
      await sub.cancel();
      await socket.close();
    });
    Future<void> until(bool Function() p) async {
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (!p()) {
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('同步逾時');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    await controller.newTask('需求');
    await controller.revise('取消風量');
    final pending = controller.snapshot;
    bool ready(Map<String, dynamic> f) =>
        f['task']['revision'] == pending.revision &&
        f['task']['phase'] == 'awaitingConfirmation';
    await until(() => frames.any(ready));
    final sent = frames.lastWhere(ready);
    expect((sent['task']['pending'] as Map).containsKey('rearFan'), false);
    expect(sent['task']['pending']['mediaVolume'], 'decrease');
    expect(sent['cabin_state'], {
      'rearFan': 3,
      'mediaVolume': 5,
      'navVolume': 5,
    });
    socket.add(
      jsonEncode({
        'cmd': 'confirm',
        'task_id': pending.taskId,
        'revision': pending.revision,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(mock.executeCount, 0);
    await controller.confirm(pending.taskId!, pending.revision);
    await until(() => frames.any((f) => f['task']['phase'] == 'completed'));
    expect(
      frames.lastWhere(
        (f) => f['task']['phase'] == 'completed',
      )['task']['result']['simulated'],
      true,
    );
    expect(mock.executeCount, 1);
    expect(hub.status()['cabin_state'], {
      'rearFan': 3,
      'mediaVolume': 4,
      'navVolume': 5,
    });
    await controller.newTask('新的需求');
    final newId = controller.snapshot.taskId;
    await until(() => frames.any((f) => f['task']['task_id'] == newId));
    final next = frames.lastWhere((f) => f['task']['task_id'] == newId);
    expect(next['task']['result'], isNull);
    expect(next['cabin_state'], {
      'rearFan': 3,
      'mediaVolume': 4,
      'navVolume': 5,
    });
  });

  test('需求仍在解析時，原盲點規則仍經新雙屏通道即時送出', () async {
    final parserResult = Completer<IntentPatch>();
    final mock = MockCabinActuator();
    final controller = RepairController(
      parser: (_, _) => parserResult.future,
      actuator: mock.call,
    );
    final cockpit = Hub.I;
    final hub = RepairHub(
      controller,
      modelStatus: () => '解析測試替身，非Qwen',
      asset: (_) async => null,
      cockpitEvent: () => cockpit.last?.toJson(),
      cockpitSignals: cockpit,
    );
    WebSocket? socket;
    StreamSubscription<dynamic>? subscription;
    Future<bool>? parsing;
    addTearDown(() async {
      // Complete even after a failed assertion so no parser timeout outlives
      // this test. Neither completing nor clearing a warning executes a task.
      if (!parserResult.isCompleted) {
        parserResult.complete(
          IntentPatch(
            changes: {CabinSetting.mediaVolume: RequestedChange.decrease},
          ),
        );
      }
      if (parsing != null) await parsing;
      await subscription?.cancel();
      await socket?.close();
      await hub.stop();
      await cockpit.stop();
      controller.dispose();
    });

    // Reuse the original simulator and rules, without its extra HTTP/UDP
    // listeners. This exercises the actual embedded-demo integration.
    await cockpit.start(network: false);
    cockpit.clearDemoEvents();
    cockpit.setScene(Scene.normal);
    await hub.start();
    socket = await WebSocket.connect('ws://127.0.0.1:${RepairHub.port}/repair');
    final frames = <Map<String, dynamic>>[];
    subscription = socket.listen(
      (raw) => frames.add(Map<String, dynamic>.from(jsonDecode(raw))),
    );
    Future<Map<String, dynamic>> waitFor(
      bool Function(Map<String, dynamic>) matches,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(deadline)) {
        final matching = frames.reversed.where(matches);
        if (matching.isNotEmpty) return matching.first;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      throw TimeoutException('解析期間未收到預期的原座艙事件');
    }

    parsing = controller.newTask('音樂小聲一點');
    expect(controller.snapshot.phase, RepairPhase.parsing);
    cockpit.injectBlindSpot(side: 'right', object: '機車', seconds: 4);
    final warningFrame = await waitFor(
      (frame) => frame['cockpit_event']?['domain'] == 'blind_spot',
    );
    final warning = Envelope.fromJson(warningFrame['cockpit_event'])!;
    expect(warning.state['side'], 'right');
    expect(warning.state['object'], '機車');
    expect(warning.decision.action, '注意右後方機車');
    expect(warning.decision.urgency, Urgency.safety);
    expect(warning.phrase, '右後方有機車');
    expect(warning.phraseSrc, 'rule');
    expect(warning.vehicle?['turn'], 'right');
    expect(warningFrame['task']['phase'], 'parsing');
    expect(parserResult.isCompleted, false);
    expect(mock.executeCount, 0);

    cockpit.clearDemoEvents();
    final clearedEventId = cockpit.last!.eventId;
    final clearFrame = await waitFor((frame) {
      final event = frame['cockpit_event'];
      return event?['domain'] == 'cabin_air' &&
          event?['event_id'] == clearedEventId &&
          frame['task']['phase'] == 'parsing';
    });
    final cleared = Envelope.fromJson(clearFrame['cockpit_event'])!;
    expect(cleared.decision.urgency, Urgency.silent);
    expect(cleared.vehicle?['turn'], isNull);
    expect(parserResult.isCompleted, false);
    expect(mock.executeCount, 0);

    parserResult.complete(
      IntentPatch(
        changes: {CabinSetting.mediaVolume: RequestedChange.decrease},
      ),
    );
    expect(await parsing, true);
    final parsedFrame = await waitFor(
      (frame) => frame['task']['phase'] == 'awaitingConfirmation',
    );
    expect(parsedFrame['task']['pending']['mediaVolume'], 'decrease');
    expect(mock.executeCount, 0);
  });
}
