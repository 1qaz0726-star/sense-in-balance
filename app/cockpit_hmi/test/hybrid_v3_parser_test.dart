import 'package:cockpit_hmi/owner_memory.dart';
import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

const _fanDown = '{"changes":{"rearFan":"decrease"},"clarification":null}';
const _sleepy =
    '{"changes":{"rearFan":"decrease","mediaVolume":"decrease"},"clarification":null}';

RepairParser _localParser(String output, List<String> calls) => RepairParser(
  (system, _) async {
    expect(system, kRepairSystemPrompt);
    calls.add('local');
    return output;
  },
  cloud: CloudAssist(
    generate: (_, _) async {
      calls.add('cloud');
      throw StateError('An explicit local correction must not call cloud.');
    },
    isOnline: () async => true,
  ),
  recall: (_) {
    calls.add('memory');
    return {CabinSetting.rearFan: RequestedChange.increase};
  },
);

void main() {
  test(
    'V3 explicit corrected cancellation stays local in the hybrid parser',
    () async {
      final snapshot = RepairSnapshot(
        pending: {CabinSetting.rearFan: RequestedChange.increase},
      );
      for (final text in [
        '後排送風的風量不是要撤回，我剛剛取消那句不算；請改填降低一格。',
        '風量不是要取消；風量降低一格。',
        '風量先撤回；風量改成降低一格。',
        '風量不是要取消而是降低一格。',
      ]) {
        final calls = <String>[];
        final patch = await _localParser(_fanDown, calls).call(text, snapshot);
        expect(patch.changes, {
          CabinSetting.rearFan: RequestedChange.decrease,
        }, reason: text);
        expect(patch.clarification, isNull, reason: text);
        expect(patch.source, 'local');
        expect(calls, ['local'], reason: text);
        expect(
          snapshot.pending[CabinSetting.rearFan],
          RequestedChange.increase,
        );
      }
    },
  );

  test(
    'V3 last explicit intent wins without discarding another correct item',
    () async {
      final calls = <String>[];
      final snapshot = RepairSnapshot(
        pending: {
          CabinSetting.rearFan: RequestedChange.increase,
          CabinSetting.mediaVolume: RequestedChange.increase,
        },
      );
      final patch = await _localParser(
        '{"changes":{"mediaVolume":"keep","rearFan":"decrease"},"clarification":null}',
        calls,
      ).call('音樂取消那句不算，風量降低一格。', snapshot);
      expect(patch.changes, {CabinSetting.rearFan: RequestedChange.decrease});
      expect(patch.clarification, isNull);
      expect(calls, ['local']);
      expect(
        snapshot.pending[CabinSetting.mediaVolume],
        RequestedChange.increase,
      );
    },
  );

  test(
    'V3 final cancel removes a pending item; final do-not-cancel preserves it',
    () async {
      final snapshot = RepairSnapshot(
        pending: {CabinSetting.mediaVolume: RequestedChange.decrease},
      );
      final calls = <String>[];
      final parser = _localParser(
        '{"changes":{"mediaVolume":"increase"},"clarification":null}',
        calls,
      );
      final cancelled = await parser.call('音樂不要取消；音樂提高一點；音樂還是撤回。', snapshot);
      expect(cancelled.changes, {
        CabinSetting.mediaVolume: RequestedChange.remove,
      });
      final preserved = await parser.call('音樂提高一點；音樂不要取消。', snapshot);
      expect(preserved.changes, isEmpty);
      expect(preserved.clarification, isNotEmpty);
      expect(
        snapshot.pending[CabinSetting.mediaVolume],
        RequestedChange.decrease,
      );
      expect(calls, ['local', 'local']);
    },
  );

  test(
    'V3 ambiguous correction or negative operation does not invent a target',
    () async {
      final snapshot = RepairSnapshot(
        pending: {
          CabinSetting.mediaVolume: RequestedChange.increase,
          CabinSetting.rearFan: RequestedChange.increase,
        },
      );
      for (final text in ['音樂不要取消，風量也不要取消；請改填降低一格。', '音樂不要取消；音樂不要降低。']) {
        final calls = <String>[];
        final patch = await _localParser(
          '{"changes":{"mediaVolume":"decrease","rearFan":"decrease"},"clarification":null}',
          calls,
        ).call(text, snapshot);
        expect(patch.changes, isEmpty, reason: text);
        expect(patch.clarification, isNotEmpty, reason: text);
        expect(snapshot.pending.values, everyElement(RequestedChange.increase));
        expect(calls, ['local']);
      }
    },
  );

  test(
    'Hybrid cloud lesson remains a proposal and local V3 can repair its result',
    () async {
      final calls = <String>[];
      final lessons = <Map<String, dynamic>>[];
      var executions = 0;
      final parser = RepairParser(
        (system, _) async {
          expect(system, kRepairSystemPrompt);
          calls.add('local');
          return _fanDown;
        },
        cloud: CloudAssist(
          generate: (system, _) async {
            expect(system, kCloudRepairSystemPrompt);
            calls.add('cloud');
            return _sleepy;
          },
          isOnline: () async => true,
          onLesson: lessons.add,
        ),
      );
      final controller = RepairController(
        parser: parser.call,
        actuator: (_, _) async {
          executions++;
          throw StateError('No driver confirmation was given.');
        },
      );
      await controller.newTask('讓後座的小孩好睡一點');
      expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
      expect(controller.snapshot.patchSource, 'cloud');
      final patch = await parser.call('風量先撤回；風量改成降低一格。', controller.snapshot);
      expect(patch.changes, {CabinSetting.rearFan: RequestedChange.decrease});
      expect(patch.source, 'local');
      expect(calls, ['cloud', 'local']);
      expect(lessons, hasLength(1));
      expect(
        controller.snapshot.pending[CabinSetting.mediaVolume],
        RequestedChange.decrease,
      );
      expect(executions, 0);
      controller.dispose();
    },
  );

  test(
    'Hybrid offline owner recall survives V3 local cancellation changes',
    () async {
      final memory = OwnerMemory();
      await memory.remember(
        text: '讓後座的小孩好睡一點',
        changes: {
          CabinSetting.rearFan: RequestedChange.decrease,
          CabinSetting.mediaVolume: RequestedChange.decrease,
        },
        source: 'cloud',
      );
      final calls = <String>[];
      final parser = RepairParser(
        (_, _) async {
          calls.add('local');
          return _fanDown;
        },
        cloud: CloudAssist(
          generate: (_, _) async {
            calls.add('cloud');
            return _sleepy;
          },
          isOnline: () async => false,
        ),
        recall: (text) => memory.recall(text)?.changes,
      );
      final remembered = await parser.call('讓後座的小孩好睡一點喔！', RepairSnapshot());
      expect(remembered.source, 'memory');
      expect(calls, isEmpty);
      final repaired = await parser.call(
        '風量不是要取消而是降低一格。',
        RepairSnapshot(pending: remembered.changes),
      );
      expect(repaired.changes, {
        CabinSetting.rearFan: RequestedChange.decrease,
      });
      expect(repaired.source, 'local');
      expect(calls, ['local']);
      expect(memory.entries, hasLength(1));
    },
  );

  test(
    'Hybrid offline unknown phrase and invalid cloud still clarify',
    () async {
      for (final online in [false, true]) {
        var localCalls = 0;
        var cloudCalls = 0;
        final parser = RepairParser(
          (_, _) async {
            localCalls++;
            return _fanDown;
          },
          cloud: CloudAssist(
            generate: (_, _) async {
              cloudCalls++;
              return '{"changes":{"steering":"increase"},"clarification":null}';
            },
            isOnline: () async => online,
          ),
          recall: (_) => null,
        );
        final patch = await parser.call('讓後座的小孩好睡一點', RepairSnapshot());
        expect(patch.changes, isEmpty);
        expect(patch.clarification, isNotEmpty);
        expect(patch.source, 'local');
        expect(localCalls, 0);
        expect(cloudCalls, online ? 1 : 0);
      }
    },
  );
}
