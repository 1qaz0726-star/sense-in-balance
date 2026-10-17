// Opt-in live-model integration check. It is outside test/ intentionally.
// Run only after the trained server is ready; this file starts no server.
// This covers PC HTTP + production parser/authority/controller + memory-only
// actuator. It does not measure UI, ASR, Android, real vehicles or user benefit.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_remote_model.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

bool _sameEntries<K, V>(Map<K, V> actual, Map<K, V> expected) =>
    actual.length == expected.length &&
    expected.entries.every((entry) => actual[entry.key] == entry.value);

void main() {
  test(
    'trained HTTP model repairs only fan; driver confirms exactly once',
    () async {
      const url = String.fromEnvironment(
        'REPAIR_MODEL_URL',
        defaultValue: 'http://127.0.0.1:8779',
      );
      const alias = String.fromEnvironment(
        'REPAIR_MODEL_ID',
        defaultValue: 'Qwen2.5-1.5B-Cabin-v1',
      );
      const initialText = '後座風小一點，音樂也小一點，導航提示不要變。';
      const revisionText = '風量先不用改，其餘照剛剛。';
      const definedOutput = String.fromEnvironment(
        'REPAIR_TRAINED_SMOKE_OUTPUT',
      );
      final output =
          (Platform.environment['REPAIR_TRAINED_SMOKE_OUTPUT'] ?? definedOutput)
              .trim();
      final started = DateTime.now().toUtc();
      final watch = Stopwatch()..start();
      final traces = <Map<String, dynamic>>[];
      final checks = <Map<String, dynamic>>[];
      final snapshots = <String, dynamic>{};
      final model = RemoteRepairModel(
        Uri.parse(url),
        model: alias,
        timeout: const Duration(seconds: 55),
      );
      final mock = MockCabinActuator();
      final controller = RepairController(
        parser: RepairParser(model.generate, onTrace: traces.add).call,
        actuator: mock.call,
        parseTimeout: const Duration(seconds: 60),
      );
      final collaboration = RepairCollaboration(
        controller,
        demoFaultsForTesting: false,
      );
      final driver = Object();
      final passenger = Object();
      Timer? heartbeat;
      var passed = false;
      String? failure;

      void check(String description, bool condition) {
        checks.add({'description': description, 'passed': condition});
        expect(condition, isTrue, reason: description);
      }

      try {
        await model.boot();
        check('server exposes the exact trained alias', model.ready);
        check('requested model is trained alias', model.model == alias);
        check(
          'real model creates initial proposal',
          await collaboration.newTask(initialText),
        );
        final original = controller.snapshot;
        snapshots['initial'] = original.toJson();
        check(
          'initial proposal has fan down, music down and navigation keep',
          original.phase == RepairPhase.awaitingConfirmation &&
              _sameEntries(original.pending, {
                CabinSetting.rearFan: RequestedChange.decrease,
                CabinSetting.mediaVolume: RequestedChange.decrease,
                CabinSetting.navVolume: RequestedChange.keep,
              }),
        );
        check('no actuator before authorization', mock.executeCount == 0);
        check(
          'passenger cannot revise before driver grant',
          !await collaboration.revise(revisionText),
        );
        check(
          'rejected revision invokes no extra model call',
          traces.length == 1,
        );
        check(
          'passenger cannot confirm',
          !collaboration.confirm(
            passenger,
            original.taskId!,
            original.revision,
          ),
        );
        check(
          'direct controller confirmation cannot bypass authority',
          !await controller.confirm(original.taskId!, original.revision),
        );
        check(
          'driver pairs without publishing pairing code',
          collaboration.pairDriver(driver, collaboration.pairingCode) &&
              !collaboration.toJson().containsKey('pairing_code'),
        );
        // The real inference can take longer than the six-second liveness
        // window. A live driver sends heartbeats, as the actual client does.
        heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
          collaboration.heartbeat(driver);
        });
        check(
          'driver grants revision of this proposal',
          collaboration.grant(driver, original.taskId!, original.revision),
        );
        check(
          'authorized passenger revision uses real model',
          await collaboration.revise(revisionText),
        );
        final revised = controller.snapshot;
        snapshots['revised'] = revised.toJson();
        check(
          'fan edit removed and both other requests preserved',
          revised.phase == RepairPhase.awaitingConfirmation &&
              revised.taskId == original.taskId &&
              revised.revision > original.revision &&
              _sameEntries(revised.pending, {
                CabinSetting.mediaVolume: RequestedChange.decrease,
                CabinSetting.navVolume: RequestedChange.keep,
              }),
        );
        check(
          'both parses called HTTP model and retained raw diagnostics',
          traces.length == 2 &&
              traces.every(
                (trace) =>
                    trace['path'] == 'qwen' &&
                    trace['raw'] is String &&
                    (trace['raw'] as String).isNotEmpty &&
                    trace['error'] == null,
              ),
        );
        check(
          'nothing physically or virtually executed before confirmation',
          mock.executeCount == 0 &&
              _sameEntries(mock.state, {
                CabinSetting.rearFan: 3,
                CabinSetting.mediaVolume: 5,
                CabinSetting.navVolume: 5,
              }),
        );
        check(
          'stale driver confirmation is rejected',
          !collaboration.confirm(driver, original.taskId!, original.revision),
        );
        check(
          'paired passenger still cannot confirm revised proposal',
          !collaboration.confirm(passenger, revised.taskId!, revised.revision),
        );
        check(
          'controller remains protected after revision grant',
          !await controller.confirm(revised.taskId!, revised.revision),
        );

        final completed = Completer<void>();
        void taskChanged() {
          final phase = controller.snapshot.phase;
          if (completed.isCompleted) return;
          if (phase == RepairPhase.completed) {
            completed.complete();
          } else if (phase == RepairPhase.failed ||
              phase == RepairPhase.indeterminate) {
            completed.completeError(
              StateError('Actuator outcome: ${phase.name}'),
            );
          }
        }

        controller.addListener(taskChanged);
        try {
          check(
            'driver confirms current proposal',
            collaboration.confirm(driver, revised.taskId!, revised.revision),
          );
          check(
            'immediate duplicate confirmation is rejected',
            !collaboration.confirm(driver, revised.taskId!, revised.revision),
          );
          await completed.future.timeout(const Duration(seconds: 10));
        } finally {
          controller.removeListener(taskChanged);
        }
        snapshots['completed'] = controller.snapshot.toJson();
        check('actuator executed exactly once', mock.executeCount == 1);
        check(
          'simulated final values are fan 3, music 4, navigation 5',
          _sameEntries(mock.state, {
            CabinSetting.rearFan: 3,
            CabinSetting.mediaVolume: 4,
            CabinSetting.navVolume: 5,
          }),
        );
        final receipt = controller.snapshot.result;
        check(
          'completed ACK explicitly simulated; cancelled fan not executed',
          receipt != null &&
              receipt.success &&
              receipt.simulated &&
              !receipt.items.containsKey(CabinSetting.rearFan) &&
              receipt.items.length == 2,
        );
        check(
          'completed command cannot execute again',
          !collaboration.confirm(driver, revised.taskId!, revised.revision) &&
              mock.executeCount == 1,
        );
        check(
          'completion releases passenger revision grant',
          !collaboration.canRevise,
        );
        passed = true;
      } catch (error) {
        failure = error.toString();
        rethrow;
      } finally {
        heartbeat?.cancel();
        snapshots['last_observed'] = controller.snapshot.toJson();
        final report = {
          'type': 'live_trained_model_integration_smoke_not_user_study',
          'started_at_utc': started.toIso8601String(),
          'completed_at_utc': DateTime.now().toUtc().toIso8601String(),
          'passed': passed,
          'failure': failure,
          'model_url': url,
          'requested_model_id': alias,
          'reported_model_status': model.status,
          'semantic_guard_enabled': true,
          'model_call_timeout_seconds': 55,
          'controller_parse_timeout_seconds': 60,
          'fault_injection': false,
          'participants': 0,
          'ui_tested': false,
          'audio_asr_tested': false,
          'android_device_tested': false,
          'real_vehicle_connected': false,
          'actuator': 'MockCabinActuator: memory-only simulated settings',
          'initial_input': initialText,
          'revision_input': revisionText,
          'checks': checks,
          'snapshots': snapshots,
          'model_traces': traces,
          'actuator_executions': mock.executeCount,
          'final_simulated_state': {
            for (final entry in mock.state.entries) entry.key.name: entry.value,
          },
          'total_machine_elapsed_ms': watch.elapsedMilliseconds,
          'human_time_measured': false,
        };
        collaboration.dispose();
        controller.dispose();
        model.dispose();
        if (output.isNotEmpty) {
          final file = File(output);
          await file.parent.create(recursive: true);
          await file.writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
