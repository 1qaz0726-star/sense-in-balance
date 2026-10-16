import 'package:cockpit_hmi/repair_cloud_model.dart';
import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

const _sleepy =
    '{"changes":{"rearFan":"decrease","mediaVolume":"decrease"},"clarification":null}';

RepairParser _parser({
  required bool online,
  String cloudRaw = _sleepy,
  List<String>? calls,
  List<Map<String, dynamic>>? lessons,
}) => RepairParser(
  (_, _) async {
    calls?.add('local');
    return '{"changes":{"mediaVolume":"decrease"},"clarification":null}';
  },
  cloud: CloudAssist(
    generate: (system, _) async {
      calls?.add('cloud');
      expect(system, kCloudRepairSystemPrompt);
      return cloudRaw;
    },
    isOnline: () async => online,
    onLesson: lessons?.add,
  ),
);

void main() {
  test('離線：沒點名項目照舊在本地反問，不呼叫任何模型', () async {
    final calls = <String>[];
    final patch = await _parser(
      online: false,
      calls: calls,
    ).call('讓後座的小孩好睡一點', RepairSnapshot());
    expect(patch.changes, isEmpty);
    expect(patch.clarification, isNotNull);
    expect(patch.source, 'local');
    expect(calls, isEmpty);
  });

  test('連網：沒點名項目改由雲端解讀，標示來源並留下教材', () async {
    final calls = <String>[];
    final lessons = <Map<String, dynamic>>[];
    final patch = await _parser(
      online: true,
      calls: calls,
      lessons: lessons,
    ).call('讓後座的小孩好睡一點', RepairSnapshot());
    expect(patch.changes, {
      CabinSetting.rearFan: RequestedChange.decrease,
      CabinSetting.mediaVolume: RequestedChange.decrease,
    });
    expect(patch.clarification, isNull);
    expect(patch.source, 'cloud');
    expect(calls, ['cloud']);
    expect(lessons, hasLength(1));
    expect(lessons.single['teacher_raw'], _sleepy);
  });

  test('連網但雲端也反問：保留原句以便下一輪回答接上', () async {
    final patch = await _parser(
      online: true,
      cloudRaw: '{"changes":{},"clarification":"要調小音樂還是導航提示？"}',
    ).call('小聲一點', RepairSnapshot());
    expect(patch.changes, isEmpty);
    expect(patch.clarification, '要調小音樂還是導航提示？');
    expect(patch.unresolvedTextOverride, '小聲一點');
    expect(patch.source, 'cloud');
  });

  test('不支援的控制：即使連網也不送雲端', () async {
    for (final text in ['把後座車窗打開', '座椅加熱打開', '冷氣調到二十四度']) {
      final calls = <String>[];
      final patch = await _parser(
        online: true,
        calls: calls,
      ).call(text, RepairSnapshot());
      expect(patch.changes, isEmpty, reason: text);
      expect(patch.source, 'local', reason: text);
      expect(calls, isEmpty, reason: text);
    }
  });

  test('有點名項目：走端側模型，不送雲端', () async {
    final calls = <String>[];
    final patch = await _parser(
      online: true,
      calls: calls,
    ).call('音樂小聲一點', RepairSnapshot());
    expect(patch.changes, {CabinSetting.mediaVolume: RequestedChange.decrease});
    expect(patch.source, 'local');
    expect(calls, ['local']);
  });

  test('雲端輸出不合格或出錯：退回本地反問，不冒險執行', () async {
    for (final bad in ['好的，幫你調小', '{"changes":{"seatHeat":"increase"},"clarification":null}']) {
      final patch = await _parser(
        online: true,
        cloudRaw: bad,
      ).call('讓後座的小孩好睡一點', RepairSnapshot());
      expect(patch.changes, isEmpty, reason: bad);
      expect(patch.clarification, isNotNull, reason: bad);
      expect(patch.source, 'local', reason: bad);
    }
    final failing = RepairParser(
      (_, _) async => throw StateError('不該呼叫端側'),
      cloud: CloudAssist(
        generate: (_, _) async => throw const SocketExceptionStub(),
        isOnline: () async => true,
      ),
    );
    final patch = await failing.call('讓後座的小孩好睡一點', RepairSnapshot());
    expect(patch.clarification, isNotNull);
    expect(patch.source, 'local');
  });

  test('雲端結果經過控制器時，快照標示來源，仍需駕駛確認', () async {
    final controller = RepairController(
      parser: _parser(online: true).call,
      actuator: (_, _) async => throw StateError('不得自動執行'),
    );
    await controller.newTask('讓後座的小孩好睡一點');
    expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
    expect(controller.snapshot.patchSource, 'cloud');
    expect(controller.snapshot.toJson()['patch_source'], 'cloud');
  });

  test('剝除 code fence 只動外層', () {
    expect(stripCodeFence('```json\n{"a":1}\n```'), '{"a":1}');
    expect(stripCodeFence('{"a":1}'), '{"a":1}');
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
