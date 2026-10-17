// Opt-in REAL V3 parsing with deterministic host modes and memory-only control.
// This is not UI, ASR, S9, user research or a real-vehicle evaluation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_remote_model.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real V3 A/B plans and interrupted B repair with explicit resume ACK',
    () async {
      final output = Platform.environment['CABIN_C_SMOKE_OUTPUT'] ?? '';
      final model = RemoteRepairModel(
        Uri.parse(
          const String.fromEnvironment(
            'REPAIR_MODEL_URL',
            defaultValue: 'http://127.0.0.1:8781',
          ),
        ),
        model: 'cabin-v3-clean-hybrid',
        timeout: const Duration(seconds: 55),
      );
      final traces = <Map<String, dynamic>>[];
      final checks = <Map<String, dynamic>>[];
      final states = <String, dynamic>{};
      final started = DateTime.now().toUtc();
      late CabinPolicy policy;
      final mock = MockCabinActuator(
        supports: (setting) => policy.profile.supported.contains(setting),
        executionContext: () => policy.executionIdentity,
      );
      final controller = RepairController(
        parser: RepairParser(model.generate, onTrace: traces.add).call,
        actuator: mock.call,
        executionContext: () => policy.executionIdentity,
        parseTimeout: const Duration(seconds: 60),
      );
      policy = CabinPolicy(controller);
      final collaboration = RepairCollaboration(
        controller,
        policy: policy,
        demoFaultsForTesting: false,
      );
      final driver = Object();
      var sequence = 0;
      var mode = CabinDrivingMode.manual;
      var priority = false;
      var drivingEpisode = 'baseline-mode';
      var alertEpisode = 'baseline-alert';
      Timer? heartbeat;
      var passed = false;
      String? failure;

      void check(String name, bool value) {
        checks.add({'description': name, 'passed': value});
        expect(value, isTrue, reason: name);
      }

      void sample() {
        policy.registerSource(
          CabinPolicy.drivingSource,
          '${policy.sessionId}-driving',
        );
        policy.registerSource(
          CabinPolicy.safetySource,
          '${policy.sessionId}-safety',
        );
        policy.observe(
          CabinAttentionFrame(
            sourceId: CabinPolicy.drivingSource,
            sourceSession: '${policy.sessionId}-driving',
            sequence: ++sequence,
            episodeId: drivingEpisode,
            sampledAt: policy.monotonicNow,
            mode: mode,
            active: mode == CabinDrivingMode.handoverRequested,
          ),
        );
        policy.observe(
          CabinAttentionFrame(
            sourceId: CabinPolicy.safetySource,
            sourceSession: '${policy.sessionId}-safety',
            sequence: ++sequence,
            episodeId: alertEpisode,
            sampledAt: policy.monotonicNow,
            active: priority,
          ),
        );
        if (collaboration.isDriver(driver)) {
          collaboration.heartbeat(driver, sessionId: policy.sessionId);
        }
      }

      void capture(String name) => states[name] = {
        'task': controller.snapshot.toJson(),
        'cabin_context': policy.toJson(),
        'actuator_executions': mock.executeCount,
      };
      Future<void> completed() async {
        final end = DateTime.now().add(const Duration(seconds: 2));
        while (controller.snapshot.phase != RepairPhase.completed) {
          if (DateTime.now().isAfter(end)) {
            throw StateError('ACK not completed');
          }
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }

      bool confirm({
        bool resume = false,
        CabinContextIdentity? context,
        int? revision,
      }) => collaboration.confirm(
        driver,
        controller.snapshot.taskId!,
        revision ?? controller.snapshot.revision,
        context: context ?? policy.identity,
        resume: resume,
      );
      const initial = '後座風小一點，音樂也小一點，導航提示不要變。';
      const revise = '風量先不用改，其餘照剛剛。';
      try {
        sample();
        heartbeat = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => sample(),
        );
        await model.boot();
        check(
          'pinned V3 alias is ready',
          model.ready && model.model == 'cabin-v3-clean-hybrid',
        );
        check(
          'A real model parses initial request',
          await collaboration.newTask(initial),
        );
        check(
          'A supports all three proposed semantic settings',
          policy.capabilityReady && controller.snapshot.pending.length == 3,
        );
        capture('A_proposed');
        check('A has no actuation before confirmation', mock.executeCount == 0);
        check(
          'A driver pairs',
          collaboration.pairDriver(
            driver,
            collaboration.pairingCode,
            sessionId: policy.sessionId,
          ),
        );
        check('A explicit confirmation admitted', confirm());
        await completed();
        capture('A_completed');
        check(
          'A mock actual final 2/4/5',
          mock.state[CabinSetting.rearFan] == 2 &&
              mock.state[CabinSetting.mediaVolume] == 4 &&
              mock.state[CabinSetting.navVolume] == 5,
        );
        check(
          'A complete structured ACK has cabin identity',
          controller.snapshot.result!.executionContext?['cabin_session_id'] ==
                  policy.sessionId &&
              controller.snapshot.result!.items.length == 3,
        );
        final oldIdentity = policy.identity;
        check(
          'active-driving profile replacement denied',
          !collaboration.startCabinSession(CabinProfile.b, parked: false),
        );
        check(
          'clean parked profile replacement admitted',
          collaboration.startCabinSession(CabinProfile.b, parked: true),
        );
        mock.reset();
        sample();
        check(
          'new B session cleared pairing and lease',
          !collaboration.driverOnline &&
              !collaboration.canRevise &&
              oldIdentity.cabinSessionId != policy.sessionId,
        );
        check(
          'B same sentence really parsed again',
          await collaboration.newTask(initial),
        );
        capture('B_blocked_capability');
        check(
          'B retains unsupported fan instead of dropping it',
          controller.snapshot.pending.containsKey(CabinSetting.rearFan) &&
              policy.unsupported.containsKey(CabinSetting.rearFan),
        );
        check(
          'B driver pairs in its own session',
          collaboration.pairDriver(
            driver,
            collaboration.pairingCode,
            sessionId: policy.sessionId,
          ),
        );
        check(
          'B unsupported confirmation refused at backend',
          !confirm() && mock.executeCount == 0,
        );
        check(
          'B cannot switch profile while candidate exists',
          !collaboration.startCabinSession(CabinProfile.a, parked: true),
        );
        check(
          'B grants only current-task revision rights',
          collaboration.grant(
            driver,
            controller.snapshot.taskId!,
            controller.snapshot.revision,
            context: policy.identity,
          ),
        );
        final beforeAttention = policy.identity;
        final oldRevision = controller.snapshot.revision;
        drivingEpisode = 'handover-demo-1';
        mode = CabinDrivingMode.handoverRequested;
        alertEpisode = 'blindspot-demo-1';
        priority = true;
        sample();
        capture('B_two_attention_blockers');
        check(
          'two distinct attention blockers are active',
          policy.blocked &&
              policy.blockers.contains('handover_requested') &&
              policy.blockers.contains('priority_alert'),
        );
        check('old epoch confirm refused', !confirm(context: beforeAttention));
        check('new epoch confirm also refused while blocked', !confirm());
        check(
          'direct controller cannot bypass policy authority',
          !await controller.confirm(
            controller.snapshot.taskId!,
            controller.snapshot.revision,
          ),
        );
        check(
          'validly authorized passenger revises using actual V3 while blocked',
          await collaboration.revise(revise),
        );
        capture('B_revised_during_block');
        check(
          'only fan removed, media/nav intent retained',
          controller.snapshot.pending.length == 2 &&
              controller.snapshot.pending[CabinSetting.mediaVolume] ==
                  RequestedChange.decrease &&
              controller.snapshot.pending[CabinSetting.navVolume] ==
                  RequestedChange.keep,
        );
        check('repair while blocked did not actuate', mock.executeCount == 0);
        priority = false;
        sample();
        check(
          'clearing one blocker does not clear the other',
          policy.blocked && policy.blockers.contains('handover_requested'),
        );
        mode = CabinDrivingMode.manual;
        sample();
        capture('B_resume_required');
        check(
          'all clear retains request and requires explicit resume',
          !policy.blocked && policy.resumeRequired && mock.executeCount == 0,
        );
        check('ordinary confirm cannot silently resume', !confirm());
        check(
          'old task revision cannot resume',
          !confirm(resume: true, revision: oldRevision),
        );
        check(
          'latest explicit resume confirmation admitted',
          confirm(resume: true),
        );
        await completed();
        capture('B_completed');
        check(
          'B mock final 3/4/5 and exactly one execution',
          mock.executeCount == 1 &&
              mock.state[CabinSetting.rearFan] == 3 &&
              mock.state[CabinSetting.mediaVolume] == 4 &&
              mock.state[CabinSetting.navVolume] == 5,
        );
        check(
          'B ACK has only approved media/nav, no fan command',
          controller.snapshot.result!.items.length == 2 &&
              !controller.snapshot.result!.items.containsKey(
                CabinSetting.rearFan,
              ),
        );
        check(
          'repeat resume does not execute again',
          !confirm(resume: true) && mock.executeCount == 1,
        );
        check(
          'all three actual model traces retained raw, no semantic guard substitution',
          traces.length == 3 &&
              traces.every(
                (t) =>
                    t['path'] == 'qwen' &&
                    t['error'] == null &&
                    (t['guard_actions'] as List).isEmpty,
              ),
        );
        passed = true;
      } catch (error) {
        failure = error.toString();
        rethrow;
      } finally {
        heartbeat?.cancel();
        final result = {
          'type': 'C_real_model_controller_integration_not_UI_or_user_study',
          'started_at_utc': started.toIso8601String(),
          'ended_at_utc': DateTime.now().toUtc().toIso8601String(),
          'passed': passed,
          'failure': failure,
          'model': model.model,
          'signals':
              'deterministic privileged host simulator, no DMS or actual takeover sensing',
          'participants': 0,
          'physical_S9': false,
          'real_vehicle': false,
          'UI_tested_here': false,
          'checks': checks,
          'snapshots': states,
          'model_traces': traces,
        };
        if (output.isNotEmpty) {
          final file = File(output);
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(result),
          );
        }
        collaboration.dispose();
        policy.dispose();
        controller.dispose();
        model.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
