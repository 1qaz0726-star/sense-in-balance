import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

IntentPatch _fanMusic() => IntentPatch(
  changes: {
    CabinSetting.rearFan: RequestedChange.decrease,
    CabinSetting.mediaVolume: RequestedChange.decrease,
  },
);

class _Fixture {
  _Fixture({CabinProfile profile = CabinProfile.a, IntentParser? parser}) {
    mock = MockCabinActuator(
      supports: (setting) => policy.profile.supported.contains(setting),
      executionContext: () => policy.executionIdentity,
    );
    controller = RepairController(
      parser: parser ?? (_, _) async => _fanMusic(),
      actuator: mock.call,
      executionContext: () => policy.executionIdentity,
    );
    policy = CabinPolicy(
      controller,
      profile: profile,
      monotonicNow: () => elapsed,
    );
    collaboration = RepairCollaboration(
      controller,
      policy: policy,
      clock: () => now,
    );
    policy.registerSource(CabinPolicy.drivingSource, 'drive');
    policy.registerSource(CabinPolicy.safetySource, 'safety');
    signals();
  }
  DateTime now = DateTime.utc(2026, 10, 18);
  Duration elapsed = const Duration(seconds: 1);
  final driver = Object();
  late final MockCabinActuator mock;
  late final RepairController controller;
  late final CabinPolicy policy;
  late final RepairCollaboration collaboration;
  int seq = 0;

  void signals({bool alert = false, String episode = 'safety'}) {
    policy.observe(
      CabinAttentionFrame(
        sourceId: CabinPolicy.drivingSource,
        sourceSession: 'drive',
        sequence: ++seq,
        episodeId: 'driving',
        sampledAt: elapsed,
      ),
    );
    policy.observe(
      CabinAttentionFrame(
        sourceId: CabinPolicy.safetySource,
        sourceSession: 'safety',
        sequence: seq,
        episodeId: episode,
        sampledAt: elapsed,
        active: alert,
      ),
    );
  }

  void pair() => expect(
    collaboration.pairDriver(
      driver,
      collaboration.pairingCode,
      sessionId: policy.sessionId,
    ),
    true,
  );

  Future<String> say(String text, {Object? peer, String? session}) =>
      collaboration.driverRequest(
        peer ?? driver,
        text,
        sessionId: session ?? policy.sessionId,
      );
}

void main() {
  test('駕駛自己說的需求：可直接確認時直接執行，走同一個 confirm', () async {
    final f = _Fixture()..pair();
    expect(await f.say('把後座風量、音樂調小一點'), 'executed');
    await Future<void>.delayed(Duration.zero);
    expect(f.mock.executeCount, 1);
    expect(f.collaboration.toJson()['driver_origin'], isTrue);
  });

  test('未配對、舊工作階段、空白都拒絕', () async {
    final f = _Fixture();
    expect(await f.say('音樂小聲一點'), 'rejected');
    f.pair();
    expect(await f.say('音樂小聲一點', session: 'old'), 'rejected');
    expect(await f.say('   '), 'rejected');
    expect(await f.say('音樂小聲一點', peer: Object()), 'rejected');
    expect(f.mock.executeCount, 0);
  });

  test('警示中不直接執行：需求保留、停在待確認', () async {
    final f = _Fixture()..pair();
    f.signals(alert: true, episode: 'alert-1');
    expect(await f.say('把後座風量、音樂調小一點'), 'confirm');
    expect(f.controller.snapshot.phase, RepairPhase.awaitingConfirmation);
    expect(f.mock.executeCount, 0);
  });

  test('這台車不支援的項目不直接執行', () async {
    final f = _Fixture(profile: CabinProfile.b)..pair();
    expect(await f.say('把後座風量、音樂調小一點'), 'confirm');
    expect(f.mock.executeCount, 0);
  });

  test('需要澄清時回 clarify，不執行', () async {
    final f = _Fixture(
      parser: (_, _) async =>
          IntentPatch(changes: const {}, clarification: '你是指音樂還是導航？'),
    )..pair();
    expect(await f.say('小聲一點'), 'clarify');
    expect(f.mock.executeCount, 0);
  });

  test('還有一筆乘客需求在處理時，不接駕駛新需求', () async {
    final f = _Fixture()..pair();
    await f.collaboration.newTask('後座風小一點');
    expect(f.controller.snapshot.phase, RepairPhase.awaitingConfirmation);
    expect(await f.say('音樂小聲一點'), 'rejected');
    expect(f.mock.executeCount, 0);
  });
}
