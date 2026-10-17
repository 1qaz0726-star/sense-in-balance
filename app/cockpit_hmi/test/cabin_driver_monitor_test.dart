import 'package:cockpit_hmi/cabin_coordination_widgets.dart';
import 'package:cockpit_hmi/cabin_driver_monitor_source.dart';
import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fixture {
  _Fixture() {
    controller = RepairController(
      parser: (_, _) async => IntentPatch(
        changes: {CabinSetting.mediaVolume: RequestedChange.decrease},
      ),
      actuator: MockCabinActuator().call,
    );
    policy = CabinPolicy(controller, monotonicNow: () => now);
    policy.registerSource(CabinPolicy.drivingSource, 'drive');
    policy.registerSource(CabinPolicy.safetySource, 'safety');
    monitor = CabinDriverMonitorSource(policy);
  }
  Duration now = const Duration(seconds: 10);
  late final RepairController controller;
  late final CabinPolicy policy;
  late final CabinDriverMonitorSource monitor;
  int driveSeq = 0, safetySeq = 0, seq = 0;

  /// 模擬車輛訊號維持「一般駕駛、沒有警示」，讓結果只取決於駕駛監測。
  void vehicleClear() {
    policy.observe(
      CabinAttentionFrame(
        sourceId: CabinPolicy.drivingSource,
        sourceSession: 'drive',
        sequence: ++driveSeq,
        episodeId: 'drive-base',
        sampledAt: now,
      ),
    );
    policy.observe(
      CabinAttentionFrame(
        sourceId: CabinPolicy.safetySource,
        sourceSession: 'safety',
        sequence: ++safetySeq,
        episodeId: 'safety-base',
        sampledAt: now,
      ),
    );
  }

  bool dms({
    bool face = true,
    String attention = 'forward',
    String eyes = 'open',
    int? at,
  }) => monitor.sample({
    'seq': at ?? ++seq,
    'face': face,
    'attention': attention,
    'eyes': eyes,
    'away_ms': 0,
    'closure_ms': 0,
  });

  Map get attention => policy.toJson()['attention'] as Map;
}

void main() {
  test('沒有駕駛端鏡頭時不影響原本流程，狀態為 off', () {
    final f = _Fixture()..vehicleClear();
    expect(f.policy.blocked, isFalse);
    expect(f.attention['driver_monitor']['state'], 'off');
    expect(cabinDriverMonitorLabel(f.policy.toJson()), isNull);
  });

  test('視線偏離 3 秒以上 → 暫停確認；看回前方 → 解除並要求確認最新版', () async {
    final f = _Fixture()..vehicleClear();
    await f.controller.newTask('音樂小聲一點');
    expect(f.dms(), isTrue);
    expect(f.policy.blocked, isFalse);
    expect(f.attention['driver_monitor']['state'], 'live');

    expect(f.dms(attention: 'long_distraction'), isTrue);
    expect(f.policy.blockers, contains('driver_distracted'));
    expect(f.policy.canConfirm(resume: false), isFalse);
    expect(cabinAttentionHeadline(f.policy.toJson()), '視線離開道路，請先看路');

    expect(f.dms(), isTrue);
    expect(f.policy.blocked, isFalse);
    expect(f.policy.resumeRequired, isTrue, reason: '解除後要駕駛確認最新版，不自動續辦');
  });

  test('閉眼 ≥1 秒（微睡以上）→ drowsy；一般眨眼不暫停', () {
    final f = _Fixture()..vehicleClear();
    f.dms(eyes: 'blink');
    f.dms(eyes: 'long_blink');
    expect(f.policy.blocked, isFalse);
    f.dms(eyes: 'microsleep');
    expect(f.policy.blockers, contains('driver_drowsy'));
    expect(cabinAttentionHeadline(f.policy.toJson()), '偵測到閉眼，請先休息');
    expect(cabinDriverMonitorLabel(f.policy.toJson()), '駕駛監測：閉眼');
  });

  test('偵測不到臉：不鎖住系統，畫面標示', () {
    final f = _Fixture()..vehicleClear();
    f.dms(face: false, attention: 'long_distraction', eyes: 'sleep');
    expect(f.policy.blocked, isFalse);
    expect(f.attention['driver_monitor']['state'], 'no_face');
    expect(cabinDriverMonitorLabel(f.policy.toJson()), '駕駛監測：偵測不到臉');
  });

  test('訊號過期（超過 3 秒沒新樣本）不再暫停，標示訊號中斷', () {
    final f = _Fixture()..vehicleClear();
    f.dms(attention: 'long_distraction');
    expect(f.policy.blockers, contains('driver_distracted'));
    f.now += const Duration(seconds: 4);
    f.vehicleClear();
    expect(f.policy.blockers, isNot(contains('driver_distracted')));
    expect(f.attention['driver_monitor']['state'], 'stale');
  });

  test('格式不對、序號倒退一律拒收', () {
    final f = _Fixture()..vehicleClear();
    expect(f.dms(at: 5), isTrue);
    expect(f.dms(at: 5, attention: 'long_distraction'), isFalse);
    expect(f.policy.blocked, isFalse);
    expect(f.monitor.sample({'seq': 9}), isFalse);
    expect(
      f.monitor.sample({
        'seq': 10,
        'face': true,
        'attention': 'asleep_at_wheel',
        'eyes': 'open',
        'away_ms': 0,
        'closure_ms': 0,
      }),
      isFalse,
    );
  });

  test('車輛來源不能冒充真實訊號；只有駕駛監測可 simulated=false', () {
    final f = _Fixture();
    expect(
      f.policy.observe(
        CabinAttentionFrame(
          sourceId: CabinPolicy.safetySource,
          sourceSession: 'safety',
          sequence: 99,
          episodeId: 'x',
          sampledAt: f.now,
          simulated: false,
        ),
      ),
      isFalse,
    );
  });

  test('偏離中改成閉眼：原因跟著換，不會卡在舊事件', () {
    final f = _Fixture()..vehicleClear();
    f.dms(attention: 'long_distraction');
    expect(f.policy.blockers, contains('driver_distracted'));
    f.dms(attention: 'long_distraction', eyes: 'sleep');
    expect(f.policy.blockers, contains('driver_drowsy'));
    expect(f.policy.blockers, isNot(contains('driver_distracted')));
    f.dms();
    expect(f.policy.blocked, isFalse);
  });
}
