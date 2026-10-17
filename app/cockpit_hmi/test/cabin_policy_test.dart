import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fixture {
  _Fixture({CabinProfile profile = CabinProfile.a}) {
    controller = RepairController(
      parser: (_, _) async => IntentPatch(
        changes: {
          CabinSetting.rearFan: RequestedChange.decrease,
          CabinSetting.mediaVolume: RequestedChange.decrease,
          CabinSetting.navVolume: RequestedChange.keep,
        },
      ),
      actuator: MockCabinActuator().call,
    );
    policy = CabinPolicy(controller, profile: profile, monotonicNow: () => now);
    register();
  }
  Duration now = const Duration(seconds: 10);
  late final RepairController controller;
  late final CabinPolicy policy;
  int drivingSequence = 0;
  int safetySequence = 0;
  String get drivingSession => '${policy.sessionId}_driving';
  String get safetySession => '${policy.sessionId}_safety';
  void register() {
    expect(
      policy.registerSource(CabinPolicy.drivingSource, drivingSession),
      true,
    );
    expect(
      policy.registerSource(CabinPolicy.safetySource, safetySession),
      true,
    );
    drivingSequence = safetySequence = 0;
  }

  bool driving({
    CabinDrivingMode mode = CabinDrivingMode.manual,
    String episode = 'drive-baseline',
    Duration? sampledAt,
    int? sequence,
    String? sourceSession,
    bool known = true,
    bool simulated = true,
  }) => policy.observe(
    CabinAttentionFrame(
      sourceId: CabinPolicy.drivingSource,
      sourceSession: sourceSession ?? drivingSession,
      sequence: sequence ?? ++drivingSequence,
      episodeId: episode,
      sampledAt: sampledAt ?? now,
      mode: mode,
      active: mode == CabinDrivingMode.handoverRequested,
      known: known,
      simulated: simulated,
    ),
  );

  bool safety({bool active = false, String episode = 'safety-baseline'}) =>
      policy.observe(
        CabinAttentionFrame(
          sourceId: CabinPolicy.safetySource,
          sourceSession: safetySession,
          sequence: ++safetySequence,
          episodeId: episode,
          sampledAt: now,
          active: active,
        ),
      );

  void clear() {
    expect(driving(), true);
    expect(safety(), true);
    expect(policy.blocked, false);
  }

  void dispose() {
    policy.dispose();
    controller.dispose();
  }
}

void main() {
  test('unconnected and missing one baseline remain blocked', () {
    final f = _Fixture();
    addTearDown(f.dispose);
    expect(f.policy.blocked, true);
    expect(f.policy.mode, CabinDrivingMode.unknown);
    expect(f.driving(), true);
    expect(f.policy.blocked, true);
    expect(f.policy.canGrant, false);
    expect(f.safety(), true);
    expect(f.policy.attentionPhase, CabinAttentionPhase.clear);
  });

  test('normal heartbeats do not invalidate a current confirmation epoch', () {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.clear();
    final epoch = f.policy.attentionEpoch;
    for (var i = 0; i < 10; i++) {
      f.now += const Duration(seconds: 1);
      f.driving();
      f.safety();
    }
    expect(f.policy.attentionEpoch, epoch);
    expect(f.policy.blocked, false);
  });

  test(
    'assisted mode changes epoch but grants no extra execution authority',
    () {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.clear();
      final old = f.policy.identity;
      f.driving(mode: CabinDrivingMode.assisted, episode: 'assisted');
      expect(f.policy.mode, CabinDrivingMode.assisted);
      expect(f.policy.matches(old), false);
      expect(f.policy.blocked, false);
      expect(f.controller.snapshot.phase, RepairPhase.idle);
    },
  );

  test('handover independently blocks without a blindspot event', () {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.clear();
    f.driving(mode: CabinDrivingMode.handoverRequested, episode: 'handover-1');
    expect(f.policy.blockers, contains('handover_requested'));
    expect(f.policy.blockers, isNot(contains('priority_alert')));
    expect(f.policy.canConfirm(resume: false), false);
  });

  test('clearing only one of two blockers cannot resume', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.clear();
    await f.controller.newTask('three settings');
    f.driving(mode: CabinDrivingMode.handoverRequested, episode: 'handover-1');
    f.safety(active: true, episode: 'blind-1');
    f.driving(episode: 'handover-1');
    expect(f.policy.blocked, true);
    expect(f.policy.blockers, contains('priority_alert'));
    f.safety(episode: 'blind-1');
    expect(f.policy.attentionPhase, CabinAttentionPhase.resumeRequired);
    expect(f.policy.canConfirm(resume: false), false);
    expect(f.policy.canConfirm(resume: true), true);
    expect(f.controller.snapshot.phase, RepairPhase.awaitingConfirmation);
  });

  test('TTL is enforced synchronously before the watchdog runs', () {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.clear();
    final old = f.policy.identity;
    f.now += const Duration(seconds: 3);
    expect(f.policy.matches(old), false);
    expect(f.policy.blocked, true);
    expect(f.policy.mode, CabinDrivingMode.unknown);
    expect(f.policy.blockers, contains('driving-context_stale'));
  });

  test(
    'future sample and fresh sequence with old sample do not refresh data',
    () {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.clear();
      expect(f.driving(sampledAt: f.now + const Duration(seconds: 1)), false);
      final original = f.now;
      f.now += const Duration(seconds: 2);
      expect(f.driving(sampledAt: original), true);
      f.safety();
      f.now += const Duration(seconds: 1);
      f.policy.refresh();
      expect(f.policy.blockers, contains('driving-context_stale'));
    },
  );

  test(
    'older sample, duplicate sequence, wrong session and untrusted input reject',
    () {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.clear();
      final epoch = f.policy.attentionEpoch;
      expect(
        f.driving(sampledAt: f.now - const Duration(milliseconds: 1)),
        false,
      );
      expect(f.driving(sequence: 1), false);
      expect(f.driving(sourceSession: 'different-session'), false);
      expect(f.driving(simulated: false), false);
      expect(f.policy.attentionEpoch, epoch);
      expect(f.policy.mode, CabinDrivingMode.manual);
    },
  );

  test(
    'late end cannot clear newer episode and ended episode cannot restart',
    () {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.clear();
      f.driving(mode: CabinDrivingMode.handoverRequested, episode: 'old');
      f.driving(mode: CabinDrivingMode.handoverRequested, episode: 'new');
      expect(f.driving(episode: 'old'), false);
      expect(f.policy.blockers, contains('handover_requested'));
      expect(f.driving(episode: 'new'), true);
      expect(
        f.driving(mode: CabinDrivingMode.handoverRequested, episode: 'new'),
        false,
      );
      expect(
        f.driving(mode: CabinDrivingMode.handoverRequested, episode: 'old'),
        false,
      );
      expect(f.policy.blocked, false);
    },
  );

  test(
    'source restart requires baseline and retired session cannot return',
    () {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.clear();
      final previous = f.drivingSession;
      expect(
        f.policy.registerSource(CabinPolicy.drivingSource, 'replacement'),
        true,
      );
      expect(f.policy.blocked, true);
      expect(f.driving(), false);
      expect(f.driving(sourceSession: 'replacement', sequence: 1), true);
      expect(f.policy.blocked, false);
      expect(
        f.policy.registerSource(CabinPolicy.drivingSource, previous),
        false,
      );
    },
  );

  test('unknown sample cannot clear a still active episode', () {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.clear();
    f.driving(mode: CabinDrivingMode.handoverRequested, episode: 'h1');
    f.driving(mode: CabinDrivingMode.unknown, episode: 'h1', known: false);
    expect(f.policy.blockers, contains('handover_requested'));
    expect(f.policy.mode, CabinDrivingMode.unknown);
    expect(f.driving(episode: 'h1'), true);
    expect(f.policy.blocked, false);
  });

  test('clock rollback never resurrects old freshness after catching up', () {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.clear();
    f.now -= const Duration(milliseconds: 1);
    f.policy.refresh();
    expect(f.policy.blockers, contains('clock_unconfirmed'));
    expect(f.driving(), false);
    f.now += const Duration(milliseconds: 1);
    f.policy.refresh();
    expect(f.policy.blocked, true);
    expect(f.policy.mode, CabinDrivingMode.unknown);
    f.clear();
    expect(f.policy.blocked, false);
  });

  test(
    'profile B retains unsupported intent and does not expose rear fan reading',
    () async {
      final f = _Fixture(profile: CabinProfile.b);
      addTearDown(f.dispose);
      f.clear();
      await f.controller.newTask('three settings');
      expect(f.controller.snapshot.pending.length, 3);
      expect(f.policy.unsupported.keys, [CabinSetting.rearFan]);
      expect(f.policy.capabilityReady, false);
      expect(f.policy.canConfirm(resume: false), false);
      expect(f.policy.profile.readable, isNot(contains(CabinSetting.rearFan)));
      f.controller.applyPatch(
        IntentPatch(changes: {CabinSetting.rearFan: RequestedChange.remove}),
      );
      expect(f.controller.snapshot.pending.length, 2);
      expect(f.policy.capabilityReady, true);
    },
  );

  test(
    'all unsupported stays blocked rather than treating it as empty success',
    () async {
      final f = _Fixture(profile: CabinProfile.b);
      addTearDown(f.dispose);
      f.clear();
      await f.controller.newTask('three');
      f.controller.applyPatch(
        IntentPatch(
          changes: {
            CabinSetting.mediaVolume: RequestedChange.remove,
            CabinSetting.navVolume: RequestedChange.remove,
          },
        ),
      );
      expect(f.controller.snapshot.pending.keys, [CabinSetting.rearFan]);
      expect(f.policy.canConfirm(resume: false), false);
      expect(f.controller.snapshot.phase, RepairPhase.awaitingConfirmation);
    },
  );

  test(
    'profile switch rejects moving or active task and creates clean identity',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.clear();
      final old = f.policy.identity;
      expect(f.policy.startSession(CabinProfile.b, parked: false), false);
      await f.controller.newTask('request');
      expect(f.policy.startSession(CabinProfile.b, parked: true), false);
      f.controller.cancel();
      expect(f.policy.startSession(CabinProfile.b, parked: true), true);
      expect(f.controller.snapshot.phase, RepairPhase.idle);
      expect(f.policy.sessionId, isNot(old.cabinSessionId));
      expect(f.policy.matches(old), false);
      expect(f.policy.blocked, true);
      expect(f.policy.mode, CabinDrivingMode.unknown);
      f.register();
      f.clear();
    },
  );

  test(
    'wire identity validates strict primitive types and public context is truthful',
    () async {
      final f = _Fixture(profile: CabinProfile.b);
      addTearDown(f.dispose);
      f.clear();
      await f.controller.newTask('request');
      final json = f.policy.toJson();
      expect(
        CabinContextIdentity.fromJson(json)?.cabinSessionId,
        f.policy.sessionId,
      );
      expect(
        CabinContextIdentity.fromJson({...json, 'attention_epoch': 1.0}),
        isNull,
      );
      expect(
        CabinContextIdentity.fromJson({...json, 'profile_revision': 0}),
        isNull,
      );
      expect(json['profile']['fictional'], true);
      expect(json['profile']['simulated'], true);
      expect(json['capability']['task_id'], f.controller.snapshot.taskId);
      expect(json['capability']['unsupported'].keys, ['rearFan']);
      expect(json['can_confirm'], false);
      expect(f.policy.executionIdentity.keys.toSet(), {
        'cabin_session_id',
        'profile_id',
        'profile_revision',
      });
    },
  );
}
