import 'dart:async';

import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

IntentPatch _initial() => IntentPatch(
  changes: {
    CabinSetting.rearFan: RequestedChange.decrease,
    CabinSetting.mediaVolume: RequestedChange.decrease,
    CabinSetting.navVolume: RequestedChange.keep,
  },
);

class _Fixture {
  _Fixture({IntentParser? parser, bool? demoFaultsForTesting}) {
    controller = RepairController(
      parser: parser ?? (_, _) async => _initial(),
      actuator: mock.call,
    );
    collaboration = RepairCollaboration(
      controller,
      clock: () => now,
      demoFaultsForTesting: demoFaultsForTesting,
    );
  }
  DateTime now = DateTime.utc(2026, 10, 12);
  final mock = MockCabinActuator();
  final driver = Object();
  late final RepairController controller;
  late final RepairCollaboration collaboration;
  void pair() => expect(
    collaboration.pairDriver(driver, collaboration.pairingCode),
    isTrue,
  );
  void grant() {
    final s = controller.snapshot;
    expect(collaboration.grant(driver, s.taskId!, s.revision), isTrue);
  }

  void dispose() {
    collaboration.dispose();
    controller.dispose();
  }
}

void main() {
  test('非展示模式不允許安排誤解，缺導航項與no-op都拒絕', () async {
    final disabled = _Fixture(demoFaultsForTesting: false);
    addTearDown(disabled.dispose);
    await disabled.collaboration.newTask('需求');
    expect(disabled.collaboration.injectDemoMisunderstanding(), isFalse);
    expect(
      disabled.controller.snapshot.pending[CabinSetting.navVolume],
      RequestedChange.keep,
    );
    final enabled = _Fixture(
      demoFaultsForTesting: true,
      parser: (_, _) async => IntentPatch(
        changes: {CabinSetting.mediaVolume: RequestedChange.decrease},
      ),
    );
    addTearDown(enabled.dispose);
    await enabled.collaboration.newTask('沒有導航的需求');
    expect(enabled.collaboration.injectDemoMisunderstanding(), isFalse);
    expect(enabled.collaboration.toJson().containsKey('demo_fault'), isFalse);
  });

  test('展示注入明示來源、不執行也不授權，修正後保留來源至ACK', () async {
    final f = _Fixture(demoFaultsForTesting: true);
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    final original = f.controller.snapshot;
    expect(f.collaboration.injectDemoMisunderstanding(), isTrue);
    expect(f.controller.snapshot.revision, original.revision + 1);
    expect(
      f.controller.snapshot.pending[CabinSetting.navVolume],
      RequestedChange.decrease,
    );
    expect(f.collaboration.toJson()['demo_fault'], {
      'label': '展示安排的誤解，尚未執行',
      'setting': 'navVolume',
      'before': 'keep',
      'injected': 'decrease',
      'source': 'manual_demo_injection',
      'task_id': original.taskId,
    });
    expect(f.collaboration.injectDemoMisunderstanding(), isFalse);
    expect(f.mock.executeCount, 0);
    expect(f.collaboration.canRevise, isFalse);
    expect(await f.collaboration.revise('導航不要改'), isFalse);
    f.pair();
    f.grant();
    expect(
      f.collaboration.directPatch(CabinSetting.navVolume, RequestedChange.keep),
      isTrue,
    );
    expect(f.collaboration.toJson().containsKey('demo_fault'), isTrue);
    final corrected = f.controller.snapshot;
    expect(
      f.collaboration.confirm(f.driver, corrected.taskId!, corrected.revision),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(f.collaboration.toJson().containsKey('demo_fault'), isFalse);
    expect(
      (f.collaboration.toJson()['demo_fault_source'] as Map)['source'],
      'manual_demo_injection',
    );
    expect(f.mock.state[CabinSetting.navVolume], 5);
    await f.collaboration.newTask('下一個');
    expect(f.collaboration.toJson().containsKey('demo_fault_source'), isFalse);
    expect(f.collaboration.injectDemoMisunderstanding(), isTrue);
    expect(f.collaboration.cancel(), isTrue);
    expect(f.collaboration.toJson().containsKey('demo_fault'), isFalse);
  });
  test('模型在授權期限後完成，即使watchdog尚未tick也不接受修正', () async {
    final late = Completer<IntentPatch>();
    var calls = 0;
    final f = _Fixture(
      parser: (_, _) => ++calls == 1 ? Future.value(_initial()) : late.future,
    );
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    f.pair();
    f.grant();
    final before = f.controller.snapshot;
    final parsing = f.collaboration.revise('取消風量');
    for (var i = 0; i < 23; i++) {
      f.now = f.now.add(const Duration(seconds: 5));
      expect(f.collaboration.heartbeat(f.driver), isTrue);
    }
    f.now = f.now.add(const Duration(seconds: 4));
    expect(f.collaboration.heartbeat(f.driver), isTrue);
    f.now = f.now.add(const Duration(seconds: 2));
    late.complete(
      IntentPatch(changes: {CabinSetting.rearFan: RequestedChange.remove}),
    );
    expect(await parsing, isFalse);
    expect(f.controller.snapshot.pending, before.pending);
    expect(f.mock.executeCount, 0);
  });
  test('乘客可提出需求但未授權不能改，不能直接確認，配對碼不廣播', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    final s = f.controller.snapshot;
    expect(f.collaboration.pairingCode, matches(RegExp(r'^\d{6}$')));
    expect(f.collaboration.toJson().containsKey('pairing_code'), isFalse);
    expect(await f.collaboration.revise('改一項'), isFalse);
    expect(
      f.collaboration.directPatch(CabinSetting.rearFan, RequestedChange.remove),
      isFalse,
    );
    expect(await f.controller.confirm(s.taskId!, s.revision), isFalse);
    expect(f.mock.executeCount, 0);
    expect(f.controller.snapshot.pending, s.pending);
  });

  test('唯一駕駛授權後局部修改，舊版本和其他連線不能確認', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    f.pair();
    final old = f.controller.snapshot;
    expect(
      f.collaboration.pairDriver(Object(), f.collaboration.pairingCode),
      isFalse,
    );
    expect(
      f.collaboration.grant(f.driver, old.taskId!, old.revision - 1),
      isFalse,
    );
    f.grant();
    expect(
      f.collaboration.directPatch(CabinSetting.rearFan, RequestedChange.remove),
      isTrue,
    );
    final revised = f.controller.snapshot;
    expect(revised.pending, {
      CabinSetting.mediaVolume: RequestedChange.decrease,
      CabinSetting.navVolume: RequestedChange.keep,
    });
    expect(
      f.collaboration.confirm(Object(), revised.taskId!, revised.revision),
      isFalse,
    );
    expect(
      f.collaboration.confirm(f.driver, old.taskId!, old.revision),
      isFalse,
    );
    expect(
      await f.controller.confirm(revised.taskId!, revised.revision),
      isFalse,
    );
    expect(
      f.collaboration.confirm(f.driver, revised.taskId!, revised.revision),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(f.controller.snapshot.phase, RepairPhase.completed);
    expect(f.mock.executeCount, 1);
    expect(f.mock.state[CabinSetting.mediaVolume], 4);
    expect(f.collaboration.canRevise, isFalse);
    expect(f.collaboration.toJson()['authorization_task_id'], isNull);
    expect(
      f.collaboration.confirm(f.driver, revised.taskId!, revised.revision),
      isFalse,
    );
  });

  test('逐項按鈕保留未解澄清，文字回答後才允許駕駛確認', () async {
    const question = '導航要提高還是維持原值？';
    const initialText = '風量調小，導航要提高還是維持原值';
    var calls = 0;
    final f = _Fixture(
      parser: (text, snapshot) async {
        if (++calls == 1) {
          return IntentPatch(
            changes: {CabinSetting.rearFan: RequestedChange.decrease},
            clarification: question,
          );
        }
        expect(text, '導航維持原值');
        expect(snapshot.clarification, question);
        expect(snapshot.unresolvedText, initialText);
        expect(
          snapshot.pending[CabinSetting.mediaVolume],
          RequestedChange.decrease,
        );
        return IntentPatch(
          changes: {CabinSetting.navVolume: RequestedChange.keep},
        );
      },
    );
    addTearDown(f.dispose);
    expect(await f.collaboration.newTask(initialText), isTrue);
    expect(f.controller.snapshot.phase, RepairPhase.awaitingClarification);
    f.pair();
    f.grant();
    final before = f.controller.snapshot;
    expect(
      f.collaboration.directPatch(
        CabinSetting.mediaVolume,
        RequestedChange.decrease,
      ),
      isTrue,
    );
    final edited = f.controller.snapshot;
    expect(edited.revision, before.revision + 1);
    expect(edited.phase, RepairPhase.awaitingClarification);
    expect(edited.clarification, question);
    expect(edited.unresolvedText, initialText);
    expect(edited.pending, {
      CabinSetting.rearFan: RequestedChange.decrease,
      CabinSetting.mediaVolume: RequestedChange.decrease,
    });
    expect(
      f.collaboration.confirm(f.driver, edited.taskId!, edited.revision),
      isFalse,
    );
    expect(f.mock.executeCount, 0);
    expect(await f.collaboration.revise('導航維持原值'), isTrue);
    final clarified = f.controller.snapshot;
    expect(clarified.phase, RepairPhase.awaitingConfirmation);
    expect(clarified.clarification, isNull);
    expect(clarified.unresolvedText, isNull);
    expect(clarified.pending, {
      CabinSetting.rearFan: RequestedChange.decrease,
      CabinSetting.mediaVolume: RequestedChange.decrease,
      CabinSetting.navVolume: RequestedChange.keep,
    });
    expect(
      f.collaboration.confirm(f.driver, clarified.taskId!, clarified.revision),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(f.controller.snapshot.phase, RepairPhase.completed);
    expect(f.mock.executeCount, 1);
    expect(f.mock.state, {
      CabinSetting.rearFan: 2,
      CabinSetting.mediaVolume: 4,
      CabinSetting.navVolume: 5,
    });
  });

  test('撤權使未完成解析失效但保留先前pending，舊revoke也拒絕', () async {
    final late = Completer<IntentPatch>();
    var calls = 0;
    final f = _Fixture(
      parser: (_, _) => ++calls == 1 ? Future.value(_initial()) : late.future,
    );
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    f.pair();
    f.grant();
    final original = f.controller.snapshot;
    final parsing = f.collaboration.revise('取消風量');
    final editing = f.controller.snapshot;
    expect(editing.phase, RepairPhase.parsing);
    expect(
      f.collaboration.revoke(f.driver, original.taskId!, original.revision),
      isFalse,
    );
    expect(
      f.collaboration.revoke(f.driver, editing.taskId!, editing.revision),
      isTrue,
    );
    expect(f.controller.snapshot.revision, greaterThan(editing.revision));
    expect(f.controller.snapshot.pending, original.pending);
    late.complete(
      IntentPatch(changes: {CabinSetting.rearFan: RequestedChange.remove}),
    );
    expect(await parsing, isFalse);
    expect(f.controller.snapshot.pending, original.pending);
    expect(f.mock.executeCount, 0);
  });

  test('駕駛斷線期間的模型結果不能復活修正，重新配對仍需新授權', () async {
    final late = Completer<IntentPatch>();
    var calls = 0;
    final f = _Fixture(
      parser: (_, _) => ++calls == 1 ? Future.value(_initial()) : late.future,
    );
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    f.pair();
    f.grant();
    final before = f.controller.snapshot;
    final parsing = f.collaboration.revise('取消音樂');
    f.collaboration.disconnectDriver(f.driver);
    late.complete(
      IntentPatch(changes: {CabinSetting.mediaVolume: RequestedChange.remove}),
    );
    expect(await parsing, isFalse);
    expect(f.controller.snapshot.pending, before.pending);
    expect(f.collaboration.toJson()['paired'], isFalse);
    f.pair();
    expect(f.collaboration.canRevise, isFalse);
    expect(f.mock.executeCount, 0);
  });

  test('心跳不延長120秒授權，6秒靜默失效後不能只用heartbeat恢復', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    f.pair();
    f.grant();
    for (var i = 0; i < 24; i++) {
      f.now = f.now.add(const Duration(seconds: 5));
      expect(f.collaboration.heartbeat(f.driver), isTrue);
    }
    expect(f.collaboration.driverOnline, isTrue);
    expect(f.collaboration.canRevise, isFalse);
    f.grant();
    Object? expired;
    f.collaboration.onDriverExpired = (peer) => expired = peer;
    f.now = f.now.add(const Duration(seconds: 6));
    f.collaboration.checkTimeouts();
    expect(expired, same(f.driver));
    expect(f.collaboration.driverOnline, isFalse);
    expect(f.collaboration.heartbeat(f.driver), isFalse);
    expect(f.collaboration.toJson()['paired'], isFalse);
  });

  test('取消和新任務立即撤掉舊lease，先前設定不執行', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.collaboration.newTask('需求');
    f.pair();
    f.grant();
    expect(f.collaboration.cancel(), isTrue);
    expect(f.collaboration.canRevise, isFalse);
    await f.collaboration.newTask('下一個');
    f.grant();
    final oldId = f.controller.snapshot.taskId;
    await f.collaboration.newTask('另一個');
    expect(f.controller.snapshot.taskId, isNot(oldId));
    expect(f.collaboration.canRevise, isFalse);
    expect(f.mock.executeCount, 0);
  });
}
