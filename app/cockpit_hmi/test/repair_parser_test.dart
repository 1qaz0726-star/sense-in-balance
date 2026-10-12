import 'dart:convert';

import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('模型收到待執行項、原待澄清句、問題及單詞補充，不抹去原任務', () async {
    final snapshot = RepairSnapshot(
      taskId: 'task_1',
      revision: 3,
      phase: RepairPhase.awaitingClarification,
      pending: {
        CabinSetting.rearFan: RequestedChange.decrease,
        CabinSetting.mediaVolume: RequestedChange.decrease,
        CabinSetting.navVolume: RequestedChange.keep,
      },
      unresolvedText: '那個先不要改',
      clarification: '你是指風量、音樂，還是導航提示？',
    );
    var generations = 0;
    final parser = RepairParser((system, prompt) async {
      generations++;
      expect(system, contains('不執行任何動作'));
      expect(system, contains('unresolved_text'));
      final payload = jsonDecode(prompt) as Map;
      expect(payload['pending'], {
        'rearFan': 'decrease',
        'mediaVolume': 'decrease',
        'navVolume': 'keep',
      });
      expect(payload['unresolved_text'], '那個先不要改');
      expect(payload['clarification'], '你是指風量、音樂，還是導航提示？');
      expect(payload['user_text'], '音樂');
      return '{"changes":{"mediaVolume":"remove"},"clarification":null}';
    });

    final parsed = await parser.call('音樂', snapshot);
    expect(parsed.changes, {CabinSetting.mediaVolume: RequestedChange.remove});
    expect(parsed.clarification, isNull);
    expect(generations, 1);
    // Parser 只提出差異，原待執行內容須由 controller 合併後才改變。
    expect(
      snapshot.pending[CabinSetting.mediaVolume],
      RequestedChange.decrease,
    );
    expect(snapshot.pending[CabinSetting.navVolume], RequestedChange.keep);
  });

  test('新任務模型輸入沒有殘留澄清上下文', () async {
    final parser = RepairParser((_, prompt) async {
      final payload = jsonDecode(prompt) as Map;
      expect(payload['pending'], isEmpty);
      expect(payload['unresolved_text'], isNull);
      expect(payload['clarification'], isNull);
      expect(payload['user_text'], '音樂小一點');
      return '{"changes":{"mediaVolume":"decrease"},"clarification":null}';
    });
    final parsed = await parser.call('音樂小一點', RepairSnapshot());
    expect(parsed.changes[CabinSetting.mediaVolume], RequestedChange.decrease);
  });

  test('不合法模型輸出不抽取、不補括號、不猜值或降為假成功', () async {
    for (final fixture in [
      '```json\n{"changes":{"rearFan":"decrease"},"clarification":null}\n```',
      '{"changes":{"rearFan":"decrease"},"clarification":null',
      '{"changes":{"rearFan":"lower"},"clarification":null}',
      '{"changes":{"temperature":"decrease"},"clarification":null}',
      '{"changes":{"rearFan":"decrease"},"clarification":null,"execute":true}',
    ]) {
      var generations = 0;
      final parser = RepairParser((_, _) async {
        generations++;
        return fixture;
      });
      await expectLater(
        parser.call('風量小一點', RepairSnapshot()),
        throwsFormatException,
        reason: fixture,
      );
      expect(generations, 1, reason: '不能用第二次生成掩蓋錯誤輸出');
    }
  });

  test('模型服務出錯時保留錯誤，不用固定模板冒充意圖解析', () async {
    final parser = RepairParser((_, _) async => throw StateError('模型未載入'));
    await expectLater(parser.call('音樂小一點', RepairSnapshot()), throwsStateError);
  });
}
