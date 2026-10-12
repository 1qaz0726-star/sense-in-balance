import 'dart:async';
import 'dart:convert';

import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

IntentPatch patch(
  Map<CabinSetting, RequestedChange> changes, {
  String? clarification,
}) => IntentPatch(changes: changes, clarification: clarification);

void main() {
  test('新的完整矛盾需求取代舊澄清原句，缺槽補充使用新上下文', () async {
    const oldText = '那個不用改';
    const newText = '導航音量提高，但導航音量維持原值。';
    const oldQuestion = '你是指風量、音樂，還是導航？';
    const newQuestion = '導航音量要提高，還是維持原值？';
    final controller = RepairController(
      parser: (text, snapshot) async {
        if (text == oldText) {
          return IntentPatch(changes: {}, clarification: oldQuestion);
        }
        if (text == newText) {
          expect(snapshot.unresolvedText, oldText);
          return IntentPatch(
            changes: {},
            clarification: newQuestion,
            unresolvedTextOverride: newText,
          );
        }
        expect(text, '維持原值');
        expect(snapshot.unresolvedText, newText);
        expect(snapshot.clarification, newQuestion);
        expect(snapshot.unresolvedText, isNot(oldText));
        return IntentPatch(
          changes: {CabinSetting.navVolume: RequestedChange.keep},
        );
      },
      actuator: MockCabinActuator().call,
    );
    addTearDown(controller.dispose);
    await controller.newTask(oldText);
    await controller.revise(newText);
    expect(controller.snapshot.phase, RepairPhase.awaitingClarification);
    expect(controller.snapshot.unresolvedText, newText);
    expect(controller.snapshot.clarification, newQuestion);
    await controller.revise('維持原值');
    expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
    expect(
      controller.snapshot.pending[CabinSetting.navVolume],
      RequestedChange.keep,
    );
    expect(controller.snapshot.unresolvedText, isNull);
  });

  test('直接差異的內部澄清原句可覆寫，但模型JSON仍只接受兩欄', () async {
    final controller = RepairController(
      parser: (_, _) async => IntentPatch(changes: {}, clarification: '哪一項？'),
      actuator: MockCabinActuator().call,
    );
    addTearDown(controller.dispose);
    await controller.newTask('那個不用改');
    expect(
      controller.applyPatch(
        IntentPatch(
          changes: {},
          clarification: '是要調整風量嗎？',
          unresolvedTextOverride: '幫我把後座座椅加熱。',
        ),
      ),
      isTrue,
    );
    expect(controller.snapshot.unresolvedText, '幫我把後座座椅加熱。');
    expect(
      () => IntentPatch.fromModelOutput(
        '{"changes":{},"clarification":"哪一項？","unresolvedTextOverride":"新句子"}',
      ),
      throwsFormatException,
    );
  });
  test('模擬ACK每項記錄確切前後值與keep，去重不改紀錄', () async {
    final mock = MockCabinActuator();
    final changes = {
      CabinSetting.rearFan: RequestedChange.decrease,
      CabinSetting.navVolume: RequestedChange.keep,
    };
    final receipt = await mock.call(changes, 'items_1');
    expect(receipt.items, {
      CabinSetting.rearFan: {
        'before': 3,
        'after': 2,
        'action': 'decrease',
        'success': true,
      },
      CabinSetting.navVolume: {
        'before': 5,
        'after': 5,
        'action': 'keep',
        'success': true,
      },
    });
    expect((receipt.toJson()['items'] as Map)['navVolume']['after'], 5);
    expect(receipt.simulated, isTrue);
    expect(receipt.items.containsKey(CabinSetting.mediaVolume), isFalse);
    expect(
      () => receipt.items[CabinSetting.rearFan]!['after'] = 99,
      throwsUnsupportedError,
    );
    expect(await mock.call(changes, 'items_1'), same(receipt));
    expect(mock.executeCount, 1);
  });

  test('模擬adapter拒絕remove時逐項紀錄未執行，舊receipt可省略items', () async {
    final mock = MockCabinActuator();
    final rejected = await mock.call({
      CabinSetting.rearFan: RequestedChange.remove,
    }, 'items_bad');
    expect(rejected.items[CabinSetting.rearFan], {
      'before': 3,
      'after': 3,
      'action': 'remove',
      'success': false,
    });
    expect(mock.executeCount, 0);
    final legacy = ExecutionReceipt(success: false, message: '沒有逐項證據');
    expect(legacy.items, isEmpty);
    expect(legacy.toJson().containsKey('items'), isFalse);
  });
  test('直接差異修正失效晚到模型，未提到的待執行項保留', () async {
    final late = Completer<IntentPatch>();
    var calls = 0;
    final mock = MockCabinActuator();
    final controller = RepairController(
      parser: (_, _) => ++calls == 1
          ? Future.value(
              IntentPatch(
                changes: {
                  CabinSetting.rearFan: RequestedChange.decrease,
                  CabinSetting.mediaVolume: RequestedChange.decrease,
                },
              ),
            )
          : late.future,
      actuator: mock.call,
    );
    addTearDown(controller.dispose);
    await controller.newTask('初始需求');
    final parsing = controller.revise('另一種修改');
    expect(
      controller.applyPatch(
        IntentPatch(changes: {CabinSetting.rearFan: RequestedChange.remove}),
      ),
      isTrue,
    );
    late.complete(
      IntentPatch(
        changes: {CabinSetting.mediaVolume: RequestedChange.increase},
      ),
    );
    expect(await parsing, isFalse);
    expect(controller.snapshot.pending, {
      CabinSetting.mediaVolume: RequestedChange.decrease,
    });
    expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
    expect(mock.executeCount, 0);
  });

  group('嚴格模型輸出', () {
    test('接受完整白名單 JSON', () {
      final parsed = IntentPatch.fromModelOutput(
        '{"changes":{"rearFan":"decrease","navVolume":"keep"},"clarification":null}',
      );
      expect(parsed.changes, {
        CabinSetting.rearFan: RequestedChange.decrease,
        CabinSetting.navVolume: RequestedChange.keep,
      });
      expect(parsed.clarification, isNull);
      expect(() => parsed.changes.clear(), throwsUnsupportedError);
    });

    test('不修復截斷 JSON、不抽 code fence、不吞未知欄位或型別', () {
      for (final raw in [
        '{"changes":{"rearFan":"decrease"},"clarification":null',
        '```json\n{"changes":{"rearFan":"decrease"},"clarification":null}\n```',
        '{"changes":{"temperature":"decrease"},"clarification":null}',
        '{"changes":{"rearFan":"set"},"clarification":null}',
        '{"changes":{"rearFan":1},"clarification":null}',
        '{"changes":{"rearFan":"decrease"},"clarification":null,"execute":true}',
        '{"changes":{"rearFan":"decrease"}}',
        '{"changes":[],"clarification":null}',
        '{"changes":{},"clarification":false}',
        '{"changes":{},"clarification":"  "}',
        '{"changes":{},"clarification":null}',
        '{"changes":{"rearFan":"unsupported","rearFan":"decrease"},"clarification":null}',
        '{"changes":{"rearFan":"decrease","rear\\u0046an":"increase"},"clarification":null}',
      ]) {
        expect(
          () => IntentPatch.fromModelOutput(raw),
          throwsFormatException,
          reason: raw,
        );
      }
    });

    test('模糊需求可僅要求澄清', () {
      final parsed = IntentPatch.fromModelOutput(
        '{"changes":{},"clarification":"你想調小音樂還是導航？"}',
      );
      expect(parsed.changes, isEmpty);
      expect(parsed.clarification, contains('導航'));
    });
  });

  group('任務修正與確認', () {
    test('只補一個詞時，parser 收到待澄清原句與問題；解決後清空', () async {
      var count = 0;
      final controller = RepairController(
        parser: (text, snapshot) async {
          if (++count == 1) {
            expect(text, '那個小一點');
            expect(snapshot.unresolvedText, isNull);
            return patch({}, clarification: '你想調小音樂還是導航提示？');
          }
          expect(text, '音樂');
          expect(snapshot.unresolvedText, '那個小一點');
          expect(snapshot.clarification, '你想調小音樂還是導航提示？');
          return patch({CabinSetting.mediaVolume: RequestedChange.decrease});
        },
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('那個小一點');
      expect(controller.snapshot.phase, RepairPhase.awaitingClarification);
      expect(controller.snapshot.unresolvedText, '那個小一點');
      await controller.revise('音樂');
      expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
      expect(controller.snapshot.pending, {
        CabinSetting.mediaVolume: RequestedChange.decrease,
      });
      expect(controller.snapshot.unresolvedText, isNull);
      expect(controller.snapshot.clarification, isNull);
    });

    test('解析失敗保留有效澄清上下文，取消或新任務後清空', () async {
      var count = 0;
      final controller = RepairController(
        parser: (_, snapshot) async {
          count++;
          if (count == 2) throw const FormatException('輸出截斷');
          if (count == 3) {
            expect(snapshot.unresolvedText, isNull);
            expect(snapshot.clarification, isNull);
          }
          return patch({}, clarification: '你指哪一個音量？');
        },
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('那個不要改');
      await controller.revise('音樂');
      expect(controller.snapshot.phase, RepairPhase.failed);
      expect(controller.snapshot.unresolvedText, '那個不要改');
      expect(controller.snapshot.clarification, '你指哪一個音量？');
      await controller.newTask('其他那個也不要改');
      expect(controller.snapshot.unresolvedText, '其他那個也不要改');
      expect(controller.cancel(), isTrue);
      expect(controller.snapshot.unresolvedText, isNull);
      expect(controller.snapshot.clarification, isNull);
    });

    test('澄清原句最多保存 500 個 Unicode 字元，不切斷代理對', () async {
      final controller = RepairController(
        parser: (_, _) async => patch({}, clarification: '你想調整哪一項？'),
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      final longText = List.filled(600, '🙂').join();
      await controller.newTask(longText);
      expect(controller.snapshot.unresolvedText!.runes.length, 500);
      expect(controller.snapshot.unresolvedText, List.filled(500, '🙂').join());
      expect(
        controller.snapshot.toJson()['unresolved_text'],
        controller.snapshot.unresolvedText,
      );
    });

    test('取消風量待執行項；音樂與導航保留，確認前不改狀態', () async {
      final mock = MockCabinActuator();
      var parseCount = 0;
      final controller = RepairController(
        parser: (_, snapshot) async {
          parseCount++;
          if (parseCount == 1) {
            return patch({
              CabinSetting.rearFan: RequestedChange.decrease,
              CabinSetting.mediaVolume: RequestedChange.decrease,
              CabinSetting.navVolume: RequestedChange.keep,
            });
          }
          expect(
            snapshot.pending[CabinSetting.mediaVolume],
            RequestedChange.decrease,
          );
          return patch({CabinSetting.rearFan: RequestedChange.remove});
        },
        actuator: mock.call,
      );
      addTearDown(controller.dispose);

      expect(await controller.newTask('後座風小一點，音樂小一點，導航不要變'), isTrue);
      expect(mock.executeCount, 0);
      final first = controller.snapshot;
      expect(await controller.revise('風量先不用改，其餘照剛剛'), isTrue);
      final revised = controller.snapshot;
      expect(revised.taskId, first.taskId);
      expect(revised.revision, first.revision + 1);
      expect(revised.pending, {
        CabinSetting.mediaVolume: RequestedChange.decrease,
        CabinSetting.navVolume: RequestedChange.keep,
      });
      expect(mock.state[CabinSetting.mediaVolume], 5);
      expect(
        await controller.confirm(revised.taskId!, revised.revision),
        isTrue,
      );
      expect(controller.snapshot.phase, RepairPhase.completed);
      expect(controller.snapshot.result!.simulated, isTrue);
      expect(mock.state, {
        CabinSetting.rearFan: 3,
        CabinSetting.mediaVolume: 4,
        CabinSetting.navVolume: 5,
      });
      expect(mock.executeCount, 1);
    });

    test('有效修正可只替換一欄，其餘欄位不被清掉', () async {
      final answers = [
        patch({
          CabinSetting.mediaVolume: RequestedChange.decrease,
          CabinSetting.navVolume: RequestedChange.keep,
        }),
        patch({CabinSetting.mediaVolume: RequestedChange.increase}),
      ];
      final controller = RepairController(
        parser: (_, _) async => answers.removeAt(0),
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('音樂調小，導航不要動');
      await controller.revise('音樂改成調大');
      expect(controller.snapshot.pending, {
        CabinSetting.mediaVolume: RequestedChange.increase,
        CabinSetting.navVolume: RequestedChange.keep,
      });
    });

    test('舊任務或舊 revision 的確認不會執行', () async {
      final mock = MockCabinActuator();
      final controller = RepairController(
        parser: (_, _) async =>
            patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
        actuator: mock.call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('音樂調小');
      final old = controller.snapshot;
      await controller.revise('音樂再小一點');
      expect(await controller.confirm(old.taskId!, old.revision), isFalse);
      expect(
        await controller.confirm('其他任務', controller.snapshot.revision),
        isFalse,
      );
      expect(mock.executeCount, 0);
    });

    test('待澄清與錯誤 JSON 均不得執行；錯誤不抹去原任務', () async {
      final mock = MockCabinActuator();
      var count = 0;
      final controller = RepairController(
        parser: (_, _) async {
          count++;
          if (count == 1) {
            return patch({CabinSetting.mediaVolume: RequestedChange.decrease});
          }
          if (count == 2) {
            return patch({}, clarification: '哪一個音量？');
          }
          return IntentPatch.fromModelOutput('{"made_up":true}');
        },
        actuator: mock.call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('音樂调小');
      await controller.revise('那個也小一點');
      expect(controller.snapshot.phase, RepairPhase.awaitingClarification);
      expect(
        await controller.confirm(
          controller.snapshot.taskId!,
          controller.snapshot.revision,
        ),
        isFalse,
      );
      await controller.revise('導航');
      expect(controller.snapshot.phase, RepairPhase.failed);
      expect(
        controller.snapshot.pending[CabinSetting.mediaVolume],
        RequestedChange.decrease,
      );
      expect(
        await controller.confirm(
          controller.snapshot.taskId!,
          controller.snapshot.revision,
        ),
        isFalse,
      );
      expect(mock.executeCount, 0);
    });

    test('刪掉所有既有待執行項即取消，不要求使用者再提供調整', () async {
      var count = 0;
      final mock = MockCabinActuator();
      final controller = RepairController(
        parser: (_, _) async => patch({
          CabinSetting.rearFan: ++count == 1
              ? RequestedChange.decrease
              : RequestedChange.remove,
        }),
        actuator: mock.call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('風量調小');
      await controller.revise('風量先不用');
      expect(controller.snapshot.pending, isEmpty);
      expect(controller.snapshot.phase, RepairPhase.cancelled);
      expect(controller.snapshot.clarification, isNull);
      expect(
        await controller.confirm(
          controller.snapshot.taskId!,
          controller.snapshot.revision,
        ),
        isFalse,
      );
      expect(mock.executeCount, 0);
    });

    test('首次移除不存在的項目仍需澄清，不能假裝取消既有需求', () async {
      final mock = MockCabinActuator();
      final controller = RepairController(
        parser: (_, _) async =>
            patch({CabinSetting.rearFan: RequestedChange.remove}),
        actuator: mock.call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('風量先不用改');
      expect(controller.snapshot.phase, RepairPhase.awaitingClarification);
      expect(controller.snapshot.clarification, isNotNull);
      expect(mock.executeCount, 0);
    });

    test('移除全部項目但模型仍要求澄清時，不當作已取消', () async {
      var count = 0;
      final controller = RepairController(
        parser: (_, _) async => ++count == 1
            ? patch({CabinSetting.rearFan: RequestedChange.decrease})
            : patch({
                CabinSetting.rearFan: RequestedChange.remove,
              }, clarification: '你是要取消全部，還是改別項？'),
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('風量調小');
      await controller.revise('先不要改');
      expect(controller.snapshot.phase, RepairPhase.awaitingClarification);
      expect(controller.snapshot.clarification, contains('取消全部'));
    });

    test('重複確認只執行一次，執行中不假裝可以取消或重開', () async {
      final ack = Completer<ExecutionReceipt>();
      var executions = 0;
      final controller = RepairController(
        parser: (_, _) async =>
            patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
        actuator: (_, _) {
          executions++;
          return ack.future;
        },
      );
      addTearDown(controller.dispose);
      await controller.newTask('音樂調小');
      final ready = controller.snapshot;
      final completing = controller.confirm(ready.taskId!, ready.revision);
      expect(controller.snapshot.phase, RepairPhase.executing);
      expect(await controller.confirm(ready.taskId!, ready.revision), isFalse);
      expect(controller.cancel(), isFalse);
      expect(await controller.newTask('音樂調大'), isFalse);
      expect(await controller.revise('先不要改'), isFalse);
      expect(executions, 1);
      ack.complete(ExecutionReceipt(success: true, message: '模擬已完成'));
      expect(await completing, isTrue);
      expect(await controller.confirm(ready.taskId!, ready.revision), isFalse);
      expect(executions, 1);
    });

    test('負面 ACK 不會顯示已完成', () async {
      final controller = RepairController(
        parser: (_, _) async =>
            patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
        actuator: (_, _) async =>
            ExecutionReceipt(success: false, message: '控制設備拒絕執行'),
      );
      addTearDown(controller.dispose);
      await controller.newTask('音樂調小');
      final ready = controller.snapshot;
      expect(await controller.confirm(ready.taskId!, ready.revision), isFalse);
      expect(controller.snapshot.phase, RepairPhase.failed);
      expect(controller.snapshot.result!.success, isFalse);
      expect(controller.snapshot.error, '控制設備拒絕執行');
    });

    test('快照可序列化且呼叫端不能改待執行內容', () async {
      final controller = RepairController(
        parser: (_, _) async =>
            patch({CabinSetting.navVolume: RequestedChange.keep}),
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      await controller.newTask('導航不要改');
      expect(() => controller.snapshot.pending.clear(), throwsUnsupportedError);
      final decoded =
          jsonDecode(jsonEncode(controller.snapshot.toJson())) as Map;
      expect(decoded['phase'], 'awaitingConfirmation');
      expect(decoded['pending'], {'navVolume': 'keep'});
    });
  });

  group('非同步競態', () {
    test('取消後，遲到解析不能復活任務', () async {
      final parsing = Completer<IntentPatch>();
      final mock = MockCabinActuator();
      final controller = RepairController(
        parser: (_, _) => parsing.future,
        actuator: mock.call,
      );
      addTearDown(controller.dispose);
      final pending = controller.newTask('音樂調小');
      expect(controller.snapshot.phase, RepairPhase.parsing);
      expect(controller.cancel(), isTrue);
      parsing.complete(
        patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
      );
      expect(await pending, isFalse);
      expect(controller.snapshot.phase, RepairPhase.cancelled);
      expect(controller.snapshot.pending, isEmpty);
      expect(mock.executeCount, 0);
    });

    test('後來的修正先完成，舊解析不能覆蓋它', () async {
      final first = Completer<IntentPatch>();
      final second = Completer<IntentPatch>();
      var count = 0;
      final controller = RepairController(
        parser: (_, _) => ++count == 1 ? first.future : second.future,
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      final old = controller.newTask('音樂調小');
      final newer = controller.revise('音樂調大');
      second.complete(
        patch({CabinSetting.mediaVolume: RequestedChange.increase}),
      );
      expect(await newer, isTrue);
      final revision = controller.snapshot.revision;
      first.complete(
        patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
      );
      expect(await old, isFalse);
      expect(controller.snapshot.revision, revision);
      expect(
        controller.snapshot.pending[CabinSetting.mediaVolume],
        RequestedChange.increase,
      );
    });

    test('新任務取代舊任務，舊模型結果不能改新任務', () async {
      final first = Completer<IntentPatch>();
      var count = 0;
      final controller = RepairController(
        parser: (_, _) async {
          if (++count == 1) return first.future;
          return patch({CabinSetting.rearFan: RequestedChange.increase});
        },
        actuator: MockCabinActuator().call,
      );
      addTearDown(controller.dispose);
      final old = controller.newTask('音樂調小');
      final oldId = controller.snapshot.taskId;
      await controller.newTask('風量調大');
      expect(controller.snapshot.taskId, isNot(oldId));
      first.complete(
        patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
      );
      expect(await old, isFalse);
      expect(controller.snapshot.pending, {
        CabinSetting.rearFan: RequestedChange.increase,
      });
    });

    test('解析逾時不執行，晚到解析也不改失敗狀態', () async {
      final parsing = Completer<IntentPatch>();
      final mock = MockCabinActuator();
      final controller = RepairController(
        parser: (_, _) => parsing.future,
        actuator: mock.call,
        parseTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      expect(await controller.newTask('音樂調小'), isFalse);
      expect(controller.snapshot.phase, RepairPhase.failed);
      parsing.complete(
        patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.phase, RepairPhase.failed);
      expect(mock.executeCount, 0);
    });

    test('執行逾時顯示未知、不重送；遲到 ACK 可澄清結果', () async {
      final ack = Completer<ExecutionReceipt>();
      var executions = 0;
      final controller = RepairController(
        parser: (_, _) async =>
            patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
        actuator: (_, _) {
          executions++;
          return ack.future;
        },
        executionTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.newTask('音樂調小');
      final ready = controller.snapshot;
      expect(await controller.confirm(ready.taskId!, ready.revision), isFalse);
      expect(controller.snapshot.phase, RepairPhase.indeterminate);
      expect(controller.snapshot.result, isNull);
      expect(controller.cancel(), isFalse);
      expect(await controller.newTask('再調小'), isFalse);
      expect(await controller.confirm(ready.taskId!, ready.revision), isFalse);
      expect(executions, 1);
      ack.complete(ExecutionReceipt(success: true, message: '模擬執行回報已到達'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.phase, RepairPhase.completed);
      expect(executions, 1);
    });

    test('adapter 拋錯時不宣稱控制成功', () async {
      final controller = RepairController(
        parser: (_, _) async =>
            patch({CabinSetting.mediaVolume: RequestedChange.decrease}),
        actuator: (_, _) async => throw StateError('連線中斷'),
      );
      addTearDown(controller.dispose);
      await controller.newTask('音樂調小');
      final ready = controller.snapshot;
      expect(await controller.confirm(ready.taskId!, ready.revision), isFalse);
      expect(controller.snapshot.phase, RepairPhase.indeterminate);
      expect(controller.snapshot.result, isNull);
    });
  });

  test('模擬 adapter 的 command ID 去重且設定值有上下限', () async {
    final mock = MockCabinActuator(rearFan: 0, mediaVolume: 10);
    final changes = {
      CabinSetting.rearFan: RequestedChange.decrease,
      CabinSetting.mediaVolume: RequestedChange.increase,
    };
    final first = await mock.call(changes, 'command_1');
    final duplicate = await mock.call(changes, 'command_1');
    expect(identical(first, duplicate), isTrue);
    expect(mock.executeCount, 1);
    expect(mock.state[CabinSetting.rearFan], 0);
    expect(mock.state[CabinSetting.mediaVolume], 10);
    expect(first.simulated, isTrue);
    expect(first.message, contains('未連接真實車輛'));
  });
}
