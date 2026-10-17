import 'package:cockpit_hmi/cabin_cockpit_source.dart';
import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/protocol.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

Envelope _event(String id, double ts, {bool urgent = false}) => Envelope(
  eventId: id,
  ts: ts,
  source: 'L1',
  domain: 'blind_spot',
  state: const {},
  decision: Decision(
    action: urgent ? 'left car' : 'silent',
    urgency: urgent ? Urgency.safety : Urgency.silent,
  ),
);

void main() {
  late RepairController controller;
  late CabinPolicy policy;
  late CabinCockpitSource source;
  late Duration now;
  var drivingSequence = 0;
  void driving() => policy.observe(
    CabinAttentionFrame(
      sourceId: CabinPolicy.drivingSource,
      sourceSession: 'drive',
      sequence: ++drivingSequence,
      episodeId: 'drive-base',
      sampledAt: now,
    ),
  );

  setUp(() {
    now = const Duration(seconds: 10);
    drivingSequence = 0;
    controller = RepairController(
      parser: (_, _) async => IntentPatch(changes: {}),
      actuator: MockCabinActuator().call,
    );
    policy = CabinPolicy(controller, monotonicNow: () => now);
    policy.registerSource(CabinPolicy.drivingSource, 'drive');
    policy.registerSource(CabinPolicy.safetySource, 'safety');
    source = CabinCockpitSource(policy, 'safety');
    driving();
  });
  tearDown(() {
    policy.dispose();
    controller.dispose();
  });

  test(
    'safety event updates policy synchronously without waiting for heartbeat',
    () {
      source.sample(_event('clear', 100), running: true, wallNowSeconds: 100);
      expect(policy.blocked, false);
      now += const Duration(milliseconds: 1);
      source.sample(
        _event('urgent', 100.001, urgent: true),
        running: true,
        wallNowSeconds: 100.001,
      );
      expect(policy.blocked, true);
      expect(policy.blockers, contains('priority_alert'));
      expect(policy.canConfirm(resume: false), false);
    },
  );

  test('re-reading a stopped source cannot extend its original TTL', () {
    final event = _event('clear', 100);
    source.sample(event, running: true, wallNowSeconds: 100);
    now = const Duration(milliseconds: 12900);
    driving();
    source.sample(event, running: true, wallNowSeconds: 102.9);
    expect(policy.blocked, false);
    now = const Duration(seconds: 13);
    // Command-boundary refresh, with no timer/source sample in this gap.
    policy.refresh();
    expect(policy.blocked, true);
    expect(policy.blockers, contains('cockpit-safety_stale'));
  });

  test(
    'delayed initial event retains original age rather than restarting TTL',
    () {
      source.sample(_event('delayed', 98), running: true, wallNowSeconds: 100);
      expect(policy.blocked, false);
      now = const Duration(seconds: 11);
      driving();
      policy.refresh();
      expect(policy.blocked, true);
      expect(policy.blockers, contains('cockpit-safety_stale'));
    },
  );

  test(
    'clone with new ID and old timestamp cannot manufacture a fresh source',
    () {
      source.sample(_event('one', 100), running: true, wallNowSeconds: 100);
      expect(policy.blocked, false);
      now += const Duration(milliseconds: 100);
      source.sample(_event('copy', 100), running: true, wallNowSeconds: 100.1);
      expect(policy.blocked, true);
      expect(policy.blockers, contains('cockpit-safety_unknown'));
    },
  );
}
