import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/cabin_policy.dart';
import 'package:cockpit_hmi/repair_collaboration.dart';
import 'package:cockpit_hmi/repair_hub.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'schema2 socket cannot bypass capability, attention, revision or session',
    () async {
      late CabinPolicy policy;
      final mock = MockCabinActuator(
        supports: (setting) => policy.profile.supported.contains(setting),
        executionContext: () => policy.executionIdentity,
      );
      final controller = RepairController(
        parser: (text, _) async => IntentPatch(
          changes: text == 'remove fan'
              ? {CabinSetting.rearFan: RequestedChange.remove}
              : {
                  CabinSetting.rearFan: RequestedChange.decrease,
                  CabinSetting.mediaVolume: RequestedChange.decrease,
                  CabinSetting.navVolume: RequestedChange.keep,
                },
        ),
        actuator: mock.call,
        executionContext: () => policy.executionIdentity,
      );
      policy = CabinPolicy(controller, profile: CabinProfile.b);
      final collaboration = RepairCollaboration(controller, policy: policy);
      final hub = RepairHub(
        controller,
        collaboration: collaboration,
        modelStatus: () => 'fixture parser, no model inference',
        cabinState: () => {
          for (final e in mock.state.entries) e.key.name: e.value,
        },
        asset: (_) async => null,
        listenPort: 0,
      );
      final sockets = <WebSocket>[];
      final subs = <StreamSubscription>[];
      addTearDown(() async {
        for (final s in subs) {
          await s.cancel();
        }
        for (final s in sockets) {
          await s.close();
        }
        await hub.stop();
        collaboration.dispose();
        policy.dispose();
        controller.dispose();
      });
      var sequence = 0;
      const episode = 'host-demonstration-episode';
      void sources({bool handover = false}) {
        policy.registerSource(
          CabinPolicy.drivingSource,
          '${policy.sessionId}-mode',
        );
        policy.registerSource(
          CabinPolicy.safetySource,
          '${policy.sessionId}-alert',
        );
        policy.observe(
          CabinAttentionFrame(
            sourceId: CabinPolicy.drivingSource,
            sourceSession: '${policy.sessionId}-mode',
            sequence: ++sequence,
            episodeId: episode,
            sampledAt: policy.monotonicNow,
            active: handover,
            mode: handover
                ? CabinDrivingMode.handoverRequested
                : CabinDrivingMode.manual,
          ),
        );
        policy.observe(
          CabinAttentionFrame(
            sourceId: CabinPolicy.safetySource,
            sourceSession: '${policy.sessionId}-alert',
            sequence: ++sequence,
            episodeId: 'clear-alert',
            sampledAt: policy.monotonicNow,
          ),
        );
      }

      sources();
      await hub.start();
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${hub.boundPort}/repair',
      );
      sockets.add(socket);
      final frames = <Map>[];
      subs.add(socket.listen((raw) => frames.add(jsonDecode(raw) as Map)));
      Future<void> until(bool Function() predicate) async {
        final end = DateTime.now().add(const Duration(seconds: 3));
        while (!predicate()) {
          if (DateTime.now().isAfter(end)) {
            throw TimeoutException('socket response');
          }
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }

      var number = 0;
      Future<Map> command(
        String action, {
        Map<String, dynamic> extra = const {},
        bool session = true,
      }) async {
        final id = 'c-test-${++number}';
        socket.add(
          jsonEncode({
            'type': 'repair_command',
            'command_id': id,
            'action': action,
            if (session) 'cabin_session_id': policy.sessionId,
            ...extra,
          }),
        );
        await until(() => frames.any((f) => f['command_id'] == id));
        return frames.lastWhere((f) => f['command_id'] == id);
      }

      Map<String, dynamic> taskFields() => {
        'task_id': controller.snapshot.taskId,
        'revision': controller.snapshot.revision,
        ...policy.identity.toJson(),
      };
      await until(() => frames.isNotEmpty);
      expect(frames.first['schema'], 2);
      expect((frames.first['cabin_state'] as Map)['rearFan'], isNull);
      expect(
        (await command(
          'pair_driver',
          extra: {'pairing_code': collaboration.pairingCode},
          session: false,
        ))['accepted'],
        isFalse,
      );
      expect(
        (await command(
          'pair_driver',
          extra: {'pairing_code': collaboration.pairingCode},
        ))['accepted'],
        isTrue,
      );
      await collaboration.newTask('three settings');
      expect(
        (await command('confirm', extra: taskFields()))['accepted'],
        isFalse,
      );
      expect(mock.executeCount, 0);
      expect((await command('grant', extra: taskFields()))['accepted'], isTrue);
      final beforeBlock = taskFields();
      sources(handover: true);
      expect(policy.blocked, isTrue);
      expect(
        (await command('confirm', extra: beforeBlock))['accepted'],
        isFalse,
      );
      expect(
        (await command('confirm', extra: taskFields()))['accepted'],
        isFalse,
      );
      expect(
        (await command('grant', extra: taskFields()))['accepted'],
        isFalse,
      );
      expect(await collaboration.revise('remove fan'), isTrue);
      expect(
        controller.snapshot.pending.keys,
        isNot(contains(CabinSetting.rearFan)),
      );
      expect(mock.executeCount, 0);
      sources();
      expect(policy.resumeRequired, isTrue);
      expect(
        (await command('confirm', extra: taskFields()))['accepted'],
        isFalse,
      );
      expect(
        (await command(
          'resume_confirm',
          extra: {...taskFields(), 'revision': 1},
        ))['accepted'],
        isFalse,
      );
      expect(
        (await command(
          'resume_confirm',
          extra: {...taskFields(), 'unexpected': true},
        ))['accepted'],
        isFalse,
      );
      expect(
        (await command('resume_confirm', extra: taskFields()))['accepted'],
        isTrue,
      );
      await until(() => controller.snapshot.phase == RepairPhase.completed);
      expect(mock.executeCount, 1);
      expect(
        controller.snapshot.result!.items.keys,
        isNot(contains(CabinSetting.rearFan)),
      );
      final oldSession = policy.sessionId;
      final oldContext = taskFields();
      expect(
        collaboration.startCabinSession(CabinProfile.a, parked: true),
        isTrue,
      );
      expect(policy.sessionId, isNot(oldSession));
      expect(collaboration.driverOnline, isFalse);
      expect(
        (await command(
          'heartbeat',
          extra: {'cabin_session_id': oldSession},
        ))['accepted'],
        isFalse,
      );
      expect(
        (await command('resume_confirm', extra: oldContext))['accepted'],
        isFalse,
      );
      expect(mock.executeCount, 1);
    },
  );
}
