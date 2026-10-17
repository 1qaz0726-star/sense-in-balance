import 'dart:async';

import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

IntentPatch _three() => IntentPatch(
  changes: {
    CabinSetting.rearFan: RequestedChange.decrease,
    CabinSetting.mediaVolume: RequestedChange.decrease,
    CabinSetting.navVolume: RequestedChange.keep,
  },
);

class _Fixture {
  _Fixture({
    CabinProfile profile = CabinProfile.a,
    IntentParser? parser,
    CabinActuator? actuator,
    Duration executionTimeout = const Duration(seconds: 8),
  }) {
    mock = MockCabinActuator(
      supports: (setting) => policy.profile.supported.contains(setting),
      executionContext: () => policy.executionIdentity,
    );
    controller = RepairController(
      parser: parser ?? (_, _) async => _three(),
      actuator: actuator ?? mock.call,
      executionContext: () => policy.executionIdentity,
      executionTimeout: executionTimeout,
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
    register();
    drive();
    safety();
  }
  DateTime now = DateTime.utc(2026, 10, 17);
  Duration elapsed = const Duration(seconds: 1);
  final driver = Object();
  late final MockCabinActuator mock;
  late final RepairController controller;
  late final CabinPolicy policy;
  late final RepairCollaboration collaboration;
  int driveSeq = 0, safetySeq = 0;
  String get driveSession => '${policy.sessionId}_driving';
  String get safetySession => '${policy.sessionId}_safety';
  void register() {
    policy.registerSource(CabinPolicy.drivingSource, driveSession);
    policy.registerSource(CabinPolicy.safetySource, safetySession);
    driveSeq = safetySeq = 0;
  }

  void drive({bool handover = false, String episode = 'driving'}) =>
      policy.observe(
        CabinAttentionFrame(
          sourceId: CabinPolicy.drivingSource,
          sourceSession: driveSession,
          sequence: ++driveSeq,
          episodeId: episode,
          sampledAt: elapsed,
          mode: handover
              ? CabinDrivingMode.handoverRequested
              : CabinDrivingMode.manual,
          active: handover,
        ),
      );

  void safety({bool active = false, String episode = 'safety'}) =>
      policy.observe(
        CabinAttentionFrame(
          sourceId: CabinPolicy.safetySource,
          sourceSession: safetySession,
          sequence: ++safetySeq,
          episodeId: episode,
          sampledAt: elapsed,
          active: active,
        ),
      );

  void advance(Duration delta) {
    now = now.add(delta);
    elapsed += delta;
  }

  void pair() => expect(
    collaboration.pairDriver(
      driver,
      collaboration.pairingCode,
      sessionId: policy.sessionId,
    ),
    true,
  );

  bool grant({CabinContextIdentity? context}) {
    final task = controller.snapshot;
    return collaboration.grant(
      driver,
      task.taskId!,
      task.revision,
      context: context ?? policy.identity,
    );
  }

  bool confirm({CabinContextIdentity? context, bool resume = false}) {
    final task = controller.snapshot;
    return collaboration.confirm(
      driver,
      task.taskId!,
      task.revision,
      context: context ?? policy.identity,
      resume: resume,
    );
  }

  Future<void> task() async {
    expect(await collaboration.newTask('後座風小一點，音樂小一點，導航不變'), true);
  }

  void dispose() {
    collaboration.dispose();
    policy.dispose();
    controller.dispose();
  }
}

void main() {
  test('C pairing and heartbeats require current session', () {
    final f = _Fixture();
    addTearDown(f.dispose);
    expect(
      f.collaboration.pairDriver(f.driver, f.collaboration.pairingCode),
      false,
    );
    expect(
      f.collaboration.pairDriver(
        f.driver,
        f.collaboration.pairingCode,
        sessionId: 'old',
      ),
      false,
    );
    f.pair();
    expect(f.collaboration.heartbeat(f.driver), false);
    expect(
      f.collaboration.heartbeat(f.driver, sessionId: f.policy.sessionId),
      true,
    );
  });

  test(
    'wall clock rollback revokes driver and in-flight editing authority',
    () async {
      final answer = Completer<IntentPatch>();
      var parses = 0;
      final f = _Fixture(
        parser: (_, _) =>
            ++parses == 1 ? Future.value(_three()) : answer.future,
      );
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      f.grant();
      final editing = f.collaboration.revise('後風取消');
      f.now = f.now.subtract(const Duration(milliseconds: 1));
      expect(f.collaboration.driverOnline, false);
      f.collaboration.checkTimeouts();
      answer.complete(
        IntentPatch(changes: {CabinSetting.rearFan: RequestedChange.remove}),
      );
      expect(await editing, false);
      expect(f.controller.snapshot.pending.length, 3);
      expect(f.collaboration.canRevise, false);
      expect(
        f.collaboration.pairDriver(
          f.driver,
          f.collaboration.pairingCode,
          sessionId: f.policy.sessionId,
        ),
        false,
      );
      f.now = f.now.add(const Duration(milliseconds: 1));
      f.pair();
      expect(f.collaboration.canRevise, false);
      expect(f.mock.executeCount, 0);
    },
  );

  test('all C task-bound actions reject missing or stale identity', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.pair();
    await f.task();
    final task = f.controller.snapshot;
    expect(f.collaboration.grant(f.driver, task.taskId!, task.revision), false);
    expect(
      f.collaboration.confirm(f.driver, task.taskId!, task.revision),
      false,
    );
    expect(
      f.collaboration.revoke(f.driver, task.taskId!, task.revision),
      false,
    );
    expect(
      f.collaboration.cancelByDriver(f.driver, task.taskId!, task.revision),
      false,
    );
    final identity = f.policy.identity;
    final wrongProfile = CabinContextIdentity(
      cabinSessionId: identity.cabinSessionId,
      profileId: CabinProfile.b.id,
      profileRevision: identity.profileRevision,
      attentionEpoch: identity.attentionEpoch,
    );
    expect(f.grant(context: wrongProfile), false);
    expect(f.mock.executeCount, 0);
    expect(f.controller.snapshot.phase, RepairPhase.awaitingConfirmation);
  });

  test(
    'B unsupported request stays visible and zero execution until explicit remove',
    () async {
      final f = _Fixture(profile: CabinProfile.b);
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      expect(f.confirm(), false);
      expect(f.mock.executeCount, 0);
      expect(f.controller.snapshot.pending.length, 3);
      expect(f.grant(), true);
      expect(
        f.collaboration.directPatch(
          CabinSetting.rearFan,
          RequestedChange.remove,
        ),
        true,
      );
      expect(f.confirm(), true);
      await Future<void>.delayed(Duration.zero);
      expect(f.mock.executeCount, 1);
      expect(f.controller.snapshot.phase, RepairPhase.completed);
      expect(f.mock.state[CabinSetting.rearFan], 3);
      expect(f.controller.snapshot.result!.items.keys.toSet(), {
        CabinSetting.mediaVolume,
        CabinSetting.navVolume,
      });
    },
  );

  test(
    'blocked current lease can repair but no new grant or confirmation is admitted',
    () async {
      final f = _Fixture(profile: CabinProfile.b);
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      expect(f.grant(), true);
      f.drive(handover: true, episode: 'handover');
      expect(f.grant(), false);
      expect(f.confirm(), false);
      expect(f.collaboration.canRevise, true);
      expect(
        f.collaboration.directPatch(
          CabinSetting.rearFan,
          RequestedChange.remove,
        ),
        true,
      );
      expect(f.controller.snapshot.pending.keys.toSet(), {
        CabinSetting.mediaVolume,
        CabinSetting.navVolume,
      });
      expect(f.confirm(), false);
      expect(f.mock.executeCount, 0);
    },
  );

  test(
    'clear preserves proposal and one latest resume_confirm executes exactly once',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      final oldContext = f.policy.identity;
      final revision = f.controller.snapshot.revision;
      f.drive(handover: true, episode: 'h1');
      f.drive(episode: 'h1');
      expect(f.controller.snapshot.revision, revision);
      expect(f.policy.resumeRequired, true);
      expect(f.mock.executeCount, 0);
      expect(f.confirm(context: oldContext, resume: true), false);
      expect(f.confirm(), false);
      expect(f.confirm(resume: true), true);
      expect(f.confirm(resume: true), false);
      await Future<void>.delayed(Duration.zero);
      expect(f.mock.executeCount, 1);
      expect(f.controller.snapshot.phase, RepairPhase.completed);
      expect(f.policy.resumeRequired, false);
    },
  );

  test(
    'freshness expires at command boundary before the next watchdog tick',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      final context = f.policy.identity;
      f.advance(const Duration(seconds: 3));
      expect(f.confirm(context: context), false);
      expect(f.policy.blocked, true);
      expect(f.mock.executeCount, 0);
    },
  );

  test(
    'late parser cannot merge once lease expires during a blocker',
    () async {
      final answer = Completer<IntentPatch>();
      var parses = 0;
      final f = _Fixture(
        parser: (_, _) =>
            ++parses == 1 ? Future.value(_three()) : answer.future,
      );
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      f.grant();
      f.drive(handover: true, episode: 'h1');
      final pending = f.collaboration.revise('後風取消');
      // Stay paired while allowing the authorization lease to expire.
      for (var i = 0; i < 25; i++) {
        f.advance(const Duration(seconds: 5));
        f.collaboration.heartbeat(f.driver, sessionId: f.policy.sessionId);
      }
      answer.complete(
        IntentPatch(changes: {CabinSetting.rearFan: RequestedChange.remove}),
      );
      expect(await pending, false);
      expect(f.controller.snapshot.pending.length, 3);
      expect(f.collaboration.canRevise, false);
      expect(f.mock.executeCount, 0);
    },
  );

  test(
    'expired passenger lease does not erase candidate or prevent driver final confirmation',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      f.grant();
      for (var i = 0; i < 125; i++) {
        f.advance(const Duration(seconds: 1));
        f.drive();
        f.safety();
        f.collaboration.heartbeat(f.driver, sessionId: f.policy.sessionId);
      }
      expect(f.collaboration.canRevise, false);
      expect(f.controller.snapshot.pending.length, 3);
      // Frames were refreshed before admission, so only the lease expires.
      expect(f.confirm(), true);
      await Future<void>.delayed(Duration.zero);
      expect(f.mock.executeCount, 1);
    },
  );

  test(
    'session switch rejects dirty task and revokes authority on clean parked reset',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      f.grant();
      final old = f.policy.identity;
      expect(
        f.collaboration.startCabinSession(CabinProfile.b, parked: true),
        false,
      );
      expect(f.collaboration.isDriver(f.driver), true);
      f.collaboration.cancel();
      expect(
        f.collaboration.startCabinSession(CabinProfile.b, parked: false),
        false,
      );
      expect(
        f.collaboration.startCabinSession(CabinProfile.b, parked: true),
        true,
      );
      expect(f.collaboration.isDriver(f.driver), false);
      expect(f.collaboration.canRevise, false);
      expect(f.controller.snapshot.phase, RepairPhase.idle);
      expect(f.policy.matches(old), false);
      expect(f.policy.blocked, true);
      expect(
        f.collaboration.heartbeat(f.driver, sessionId: old.cabinSessionId),
        false,
      );
    },
  );

  test(
    'alert after dispatch preserves task identity and complete ACK remains valid',
    () async {
      final ack = Completer<ExecutionReceipt>();
      final f = _Fixture(actuator: (_, _) => ack.future);
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      final original = f.controller.snapshot;
      expect(f.confirm(), true);
      f.drive(handover: true, episode: 'h1');
      expect(f.controller.snapshot.phase, RepairPhase.executing);
      expect(f.controller.snapshot.revision, original.revision);
      expect(
        f.collaboration.startCabinSession(CabinProfile.b, parked: true),
        false,
      );
      ack.complete(await f.mock.call(original.pending, 'late-ack'));
      await Future<void>.delayed(Duration.zero);
      expect(f.controller.snapshot.phase, RepairPhase.completed);
      expect(f.policy.blocked, true);
      expect(
        f.controller.snapshot.result!.executionContext,
        f.policy.executionIdentity,
      );
    },
  );

  test(
    'unknown execution cannot be unlocked by alert clear or profile reset; late ACK reconciles',
    () async {
      final ack = Completer<ExecutionReceipt>();
      final f = _Fixture(
        actuator: (_, _) => ack.future,
        executionTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      final proposed = f.controller.snapshot;
      expect(f.confirm(), true);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(f.controller.snapshot.phase, RepairPhase.indeterminate);
      f.drive(handover: true, episode: 'h1');
      f.drive(episode: 'h1');
      expect(f.confirm(resume: true), false);
      expect(
        f.collaboration.startCabinSession(CabinProfile.b, parked: true),
        false,
      );
      expect(f.controller.snapshot.phase, RepairPhase.indeterminate);
      ack.complete(await f.mock.call(proposed.pending, 'late'));
      await Future<void>.delayed(Duration.zero);
      expect(f.controller.snapshot.phase, RepairPhase.completed);
      expect(f.mock.executeCount, 1);
    },
  );

  test(
    'synchronous adapter failure is admitted but remains unknown without automatic retry',
    () async {
      var calls = 0;
      final f = _Fixture(
        actuator: (_, _) {
          calls++;
          throw StateError('connection interrupted after send');
        },
      );
      addTearDown(f.dispose);
      f.pair();
      await f.task();
      expect(f.confirm(), true);
      expect(f.controller.snapshot.phase, RepairPhase.indeterminate);
      expect(f.confirm(), false);
      expect(calls, 1);
    },
  );
}
