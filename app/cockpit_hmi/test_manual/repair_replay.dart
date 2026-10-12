// Technical replay with actual local Qwen. No participants and no ASR audio.
// B/C deliberately share one state machine; an extra client proves transport,
// not human benefit. Delays exclude human reading, speaking and deciding.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_hub.dart';
import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_remote_model.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    '同一明示故障的A整段重說/B單屏局部/C双客戶端/D按鈕技術回放',
    () async {
      const url = String.fromEnvironment('REPAIR_EVAL_URL');
      const output = String.fromEnvironment('REPAIR_EVAL_OUTPUT');
      expect(url, isNotEmpty);
      expect(output, isNotEmpty);
      final model = RemoteRepairModel(Uri.parse(url));
      await model.boot();
      expect(model.ready, true);
      final results = <Map<String, dynamic>>[];
      try {
        for (final condition in ['A', 'B', 'C', 'D']) {
          final traces = <Map<String, dynamic>>[];
          final mock = MockCabinActuator();
          final controller = RepairController(
            parser: RepairParser(model.generate, onTrace: traces.add).call,
            actuator: mock.call,
          );
          final collaboration = RepairCollaboration(
            controller,
            demoFaultsForTesting: true,
          );
          final hub = RepairHub(
            controller,
            collaboration: collaboration,
            modelStatus: () => 'PC Qwen 1.5B / technical replay',
            cabinState: () => {
              for (final e in mock.state.entries) e.key.name: e.value,
            },
            asset: (_) async => null,
          );
          WebSocket? driver;
          WebSocket? observer;
          StreamSubscription<dynamic>? driverSub;
          StreamSubscription<dynamic>? observerSub;
          final frames = <Map<String, dynamic>>[];
          final observerFrames = <Map<String, dynamic>>[];
          final replies = <String, Map<String, dynamic>>{};
          var sequence = 0;
          Timer? pulse;
          Future<void> until(bool Function() predicate) async {
            final limit = DateTime.now().add(const Duration(seconds: 8));
            while (!predicate()) {
              if (DateTime.now().isAfter(limit)) {
                throw TimeoutException('Replay state did not arrive.');
              }
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          }

          Future<void> command(String action, {String? code}) async {
            final id = 'replay_${condition}_${++sequence}';
            final snap = controller.snapshot;
            driver!.add(
              jsonEncode({
                'type': 'repair_command',
                'command_id': id,
                'action': action,
                if (code != null) 'pairing_code': code,
                if (action != 'pair_driver' && action != 'heartbeat') ...{
                  'task_id': snap.taskId,
                  'revision': snap.revision,
                },
              }),
            );
            await until(() => replies.containsKey(id));
            expect(
              replies[id]!['accepted'],
              true,
              reason: replies[id]!['error']?.toString(),
            );
          }

          try {
            await hub.start();
            driver = await WebSocket.connect(
              'ws://127.0.0.1:${RepairHub.port}/repair',
            );
            driverSub = driver.listen((raw) {
              final f = Map<String, dynamic>.from(jsonDecode(raw));
              if (f['type'] == 'repair_reply') {
                replies[f['command_id']] = f;
              } else {
                frames.add(f);
              }
            });
            if (condition == 'C' || condition == 'D') {
              observer = await WebSocket.connect(
                'ws://127.0.0.1:${RepairHub.port}/repair',
              );
              observerSub = observer.listen(
                (raw) => observerFrames.add(
                  Map<String, dynamic>.from(jsonDecode(raw)),
                ),
              );
            }
            await command('pair_driver', code: collaboration.pairingCode);
            pulse = Timer.periodic(const Duration(seconds: 2), (_) {
              driver?.add(
                jsonEncode({
                  'type': 'repair_command',
                  'command_id': 'pulse_${condition}_${++sequence}',
                  'action': 'heartbeat',
                }),
              );
            });
            expect(await collaboration.newTask('後座風小一點，音樂也小一點，導航提示不要變。'), true);
            final beforeFault = controller.snapshot.toJson();
            expect(collaboration.injectDemoMisunderstanding(), true);
            final fault = hub.status()['collaboration'];
            final injected = controller.snapshot.toJson();
            expect(mock.executeCount, 0);
            await command('grant');
            final repairStart = Stopwatch()..start();
            String repairInput;
            if (condition == 'A') {
              repairInput = '後座風量維持原值，音樂小一點，導航提示不要變。';
              expect(await collaboration.newTask(repairInput), true);
            } else if (condition == 'D') {
              repairInput = '按鈕：導航維持原值，取消風量變更';
              expect(
                collaboration.directPatch(
                  CabinSetting.navVolume,
                  RequestedChange.keep,
                ),
                true,
              );
              expect(
                collaboration.directPatch(
                  CabinSetting.rearFan,
                  RequestedChange.remove,
                ),
                true,
              );
            } else {
              repairInput = '導航不要改，風量也先不用改，其餘照剛剛。';
              expect(await collaboration.revise(repairInput), true);
            }
            final repairMs = repairStart.elapsedMilliseconds;
            final revised = controller.snapshot.toJson();
            expect(
              controller.snapshot.pending,
              {
                if (condition == 'A')
                  CabinSetting.rearFan: RequestedChange.keep,
                CabinSetting.mediaVolume: RequestedChange.decrease,
                CabinSetting.navVolume: RequestedChange.keep,
              },
              reason:
                  'A rebuild explicitly keeps fan; B/C/D must remove the cancelled fan edit.',
            );
            expect(mock.executeCount, 0);
            await command('confirm');
            await until(
              () => controller.snapshot.phase == RepairPhase.completed,
            );
            await until(
              () => frames.any((f) => f['task']['phase'] == 'completed'),
            );
            if (observer != null) {
              await until(
                () => observerFrames.any(
                  (f) => f['task']['phase'] == 'completed',
                ),
              );
            }
            expect(mock.executeCount, 1);
            expect(mock.state, {
              CabinSetting.rearFan: 3,
              CabinSetting.mediaVolume: 4,
              CabinSetting.navVolume: 5,
            });
            results.add({
              'condition': condition,
              'fault_id': 'synthetic-nav-decrease-before-execution',
              'initial_values': {
                'rearFan': 3,
                'mediaVolume': 5,
                'navVolume': 5,
              },
              'before_fault': beforeFault,
              'fault_source': fault,
              'injected_proposal': injected,
              'repair_input': repairInput,
              'script_input_characters': repairInput.runes.length,
              'repair_machine_ms': repairMs,
              'through_ack_machine_ms': repairStart.elapsedMilliseconds,
              'human_time_measured': false,
              'revised_proposal': revised,
              'receipt': controller.snapshot.result?.toJson(),
              'actuator_executions': mock.executeCount,
              'client_count': observer == null ? 1 : 2,
              'client_completed_frames': frames
                  .where((f) => f['task']['phase'] == 'completed')
                  .length,
              'observer_completed_frames': observerFrames
                  .where((f) => f['task']['phase'] == 'completed')
                  .length,
              'model_traces': traces,
            });
            File(output).parent.createSync(recursive: true);
            File(output).writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert({
                'type': 'technical_replay_not_user_study',
                'participants': 0,
                'audio_asr_tested': false,
                'hardware': 'PC GGUF Q8 / localhost clients',
                'B_C_equivalence':
                    'Same model and state machine; C adds a second observing client. No human screen benefit measured.',
                'rows': results,
              }),
            );
            stdout.writeln(
              'REPLAY $condition: target 3/4/5, once executed, ${repairMs}ms scripted repair',
            );
          } finally {
            pulse?.cancel();
            await driverSub?.cancel();
            await observerSub?.cancel();
            await driver?.close();
            await observer?.close();
            await hub.stop();
            collaboration.dispose();
            controller.dispose();
          }
        }
        expect(results.length, 4);
      } finally {
        model.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
