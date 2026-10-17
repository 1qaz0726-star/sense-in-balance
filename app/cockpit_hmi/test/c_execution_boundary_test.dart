import 'dart:async';

import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

const context = <String, dynamic>{
  'cabin_session_id': 'test-cabin-session',
  'profile_id': 'fictional-cabin-b',
  'profile_revision': 1,
};
const request = {CabinSetting.mediaVolume: RequestedChange.decrease};

ExecutionReceipt ack({
  Map<String, dynamic>? identity = context,
  bool items = true,
}) => ExecutionReceipt(
  success: true,
  simulated: true,
  message: 'test mock ACK',
  executionContext: identity,
  state: const {CabinSetting.mediaVolume: 4},
  items: items
      ? const {
          CabinSetting.mediaVolume: {
            'before': 5,
            'after': 4,
            'action': 'decrease',
            'success': true,
          },
        }
      : const {},
);

void main() {
  test(
    'adapter rejects the whole unsupported batch without changing any value',
    () async {
      final mock = MockCabinActuator(
        supports: (setting) => setting != CabinSetting.rearFan,
        executionContext: () => context,
      );
      final result = await mock.call({
        CabinSetting.rearFan: RequestedChange.decrease,
        CabinSetting.mediaVolume: RequestedChange.decrease,
      }, 'unsupported-batch');
      expect(result.success, isFalse);
      expect(
        result.items.values.every((item) => item['success'] == false),
        isTrue,
      );
      expect(mock.executeCount, 0);
      expect(mock.state[CabinSetting.rearFan], 3);
      expect(mock.state[CabinSetting.mediaVolume], 5);
      expect(result.executionContext, context);
    },
  );

  test(
    'adapter rejects changed contents under a previously executed command ID',
    () async {
      final mock = MockCabinActuator(executionContext: () => context);
      final first = await mock.call(request, 'fixed-id');
      expect((await mock.call(request, 'fixed-id')), same(first));
      final changed = await mock.call({
        CabinSetting.mediaVolume: RequestedChange.increase,
      }, 'fixed-id');
      expect(changed.success, isFalse);
      expect(mock.executeCount, 1);
      expect(mock.state[CabinSetting.mediaVolume], 4);
    },
  );

  for (final kind in ['missing-context', 'wrong-session', 'missing-items']) {
    test('C ACK $kind stays unknown and cannot reset session', () async {
      final controller = RepairController(
        parser: (_, _) async => IntentPatch(changes: request),
        executionContext: () => context,
        actuator: (_, _) async => ack(
          identity: kind == 'missing-context'
              ? null
              : kind == 'wrong-session'
              ? {...context, 'cabin_session_id': 'older-cabin'}
              : context,
          items: kind != 'missing-items',
        ),
      );
      addTearDown(controller.dispose);
      await controller.newTask('music');
      final task = controller.snapshot;
      expect(await controller.confirm(task.taskId!, task.revision), isFalse);
      expect(controller.snapshot.phase, RepairPhase.indeterminate);
      expect(controller.resetForSession(), isFalse);
    });
  }

  test(
    'late valid C ACK remains accepted after a post-dispatch attention block',
    () async {
      final pending = Completer<ExecutionReceipt>();
      var permitted = true;
      var executions = 0;
      String? sentCommand;
      final controller = RepairController(
        parser: (_, _) async => IntentPatch(changes: request),
        executionContext: () => context,
        executionTimeout: const Duration(milliseconds: 10),
        actuator: (_, command) {
          executions++;
          sentCommand = command;
          return pending.future;
        },
      );
      controller.confirmationGuard = (_, _) => permitted;
      addTearDown(controller.dispose);
      await controller.newTask('music');
      final task = controller.snapshot;
      final confirming = controller.confirm(task.taskId!, task.revision);
      expect(controller.snapshot.phase, RepairPhase.executing);
      permitted = false;
      expect(controller.resetForSession(), isFalse);
      expect(await confirming, isFalse);
      expect(controller.snapshot.phase, RepairPhase.indeterminate);
      pending.complete(ack());
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.phase, RepairPhase.completed);
      expect(controller.snapshot.result!.executionContext, context);
      expect(sentCommand, startsWith('test-cabin-session:'));
      expect(executions, 1);
      expect(controller.resetForSession(), isTrue);
      expect(controller.snapshot.phase, RepairPhase.idle);
      expect(controller.snapshot.result, isNull);
    },
  );

  test(
    'session reset rejects parsing, active candidate and failed phases',
    () async {
      final pending = Completer<IntentPatch>();
      final controller = RepairController(
        parser: (_, _) => pending.future,
        actuator: (_, _) async => ack(),
      );
      addTearDown(controller.dispose);
      final parsing = controller.newTask('music');
      expect(controller.resetForSession(), isFalse);
      pending.complete(IntentPatch(changes: request));
      await parsing;
      expect(controller.resetForSession(), isFalse);
      expect(controller.cancel(), isTrue);
      expect(controller.resetForSession(), isTrue);
      final failed = RepairController(
        parser: (_, _) async => throw StateError('intent rejected'),
        actuator: (_, _) async => ack(),
      );
      addTearDown(failed.dispose);
      await failed.newTask('unknown');
      expect(failed.snapshot.phase, RepairPhase.failed);
      expect(failed.resetForSession(), isFalse);
    },
  );
}
