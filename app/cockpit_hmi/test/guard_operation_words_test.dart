import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 2026-10-17 正式考卷發現：這些常見口語原本被守門當成「沒講方向」而反問，模型根本沒被問到。
  const cases = {
    '後面冷氣出風開強一點': '{"changes":{"rearFan":"increase"},"clarification":null}',
    '導航提示音再大一格': '{"changes":{"navVolume":"increase"},"clarification":null}',
    '音樂關小、導航開大':
        '{"changes":{"mediaVolume":"decrease","navVolume":"increase"},"clarification":null}',
    '風跟音樂都調小':
        '{"changes":{"rearFan":"decrease","mediaVolume":"decrease"},"clarification":null}',
    '欸，後座的風幫我轉弱一點。': '{"changes":{"rearFan":"decrease"},"clarification":null}',
  };
  for (final entry in cases.entries) {
    test('口語方向詞交給模型：${entry.key}', () async {
      var asked = false;
      final patch = await RepairParser((_, _) async {
        asked = true;
        return entry.value;
      }).call(entry.key, RepairSnapshot());
      expect(asked, isTrue);
      expect(patch.changes, isNotEmpty);
      expect(patch.clarification, isNull);
    });
  }

  test('沒講方向仍先反問，不呼叫模型', () async {
    var asked = false;
    final patch = await RepairParser((_, _) async {
      asked = true;
      return '{"changes":{"mediaVolume":"increase"},"clarification":null}';
    }).call('音樂幫我弄一下', RepairSnapshot());
    expect(asked, isFalse);
    expect(patch.changes, isEmpty);
    expect(patch.clarification, isNotNull);
  });
}
