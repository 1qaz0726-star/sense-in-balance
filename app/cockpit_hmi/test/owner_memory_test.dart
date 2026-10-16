import 'dart:io';

import 'package:cockpit_hmi/owner_memory.dart';
import 'package:cockpit_hmi/repair_cloud_model.dart';
import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

const _sleepy = {
  CabinSetting.rearFan: RequestedChange.decrease,
  CabinSetting.mediaVolume: RequestedChange.decrease,
};

void main() {
  test('只記雲端解讀並經確認的句子；本地結果只進 L0', () async {
    final memory = OwnerMemory();
    await memory.remember(
      text: '音樂小聲一點',
      changes: {CabinSetting.mediaVolume: RequestedChange.decrease},
      source: 'local',
    );
    expect(memory.entries, isEmpty);
    expect(memory.log, hasLength(1));
    await memory.remember(
      text: '讓後座的小孩好睡一點',
      changes: _sleepy,
      source: 'cloud',
    );
    expect(memory.entries, hasLength(1));
    expect(memory.recall('讓後座的小孩好睡一點喔！')?.changes, _sleepy);
  });

  test('取消類的 remove 不記成習慣', () async {
    final memory = OwnerMemory();
    await memory.remember(
      text: '先安靜一下',
      changes: {CabinSetting.rearFan: RequestedChange.remove},
      source: 'cloud',
    );
    expect(memory.entries, isEmpty);
  });

  test('離線：記憶命中直接提出候選，不呼叫雲端也不呼叫端側', () async {
    final memory = OwnerMemory();
    await memory.remember(
      text: '讓後座的小孩好睡一點',
      changes: _sleepy,
      source: 'cloud',
    );
    final calls = <String>[];
    final parser = RepairParser(
      (_, _) async {
        calls.add('local');
        return '{}';
      },
      cloud: CloudAssist(
        generate: (_, _) async {
          calls.add('cloud');
          return '{}';
        },
        isOnline: () async => false,
      ),
      recall: (text) => memory.recall(text)?.changes,
    );
    final patch = await parser.call('讓後座的小孩好睡一點', RepairSnapshot());
    expect(patch.changes, _sleepy);
    expect(patch.source, 'memory');
    expect(calls, isEmpty);
  });

  test('記憶命中經控制器仍停在等駕駛確認', () async {
    final memory = OwnerMemory();
    await memory.remember(
      text: '讓後座的小孩好睡一點',
      changes: _sleepy,
      source: 'cloud',
    );
    final controller = RepairController(
      parser: RepairParser(
        (_, _) async => '{}',
        recall: (text) => memory.recall(text)?.changes,
      ).call,
      actuator: (_, _) async => throw StateError('不得自動執行'),
    );
    await controller.newTask('讓後座的小孩好睡一點');
    expect(controller.snapshot.phase, RepairPhase.awaitingConfirmation);
    expect(controller.snapshot.patchSource, 'memory');
  });

  test('不支援的控制不查記憶', () async {
    final memory = OwnerMemory()
      ..entries.add(
        MemoryEntry(
          phrase: '座椅加熱打開',
          changes: _sleepy,
          learnedAt: DateTime(2026),
        ),
      );
    final patch = await RepairParser(
      (_, _) async => '{}',
      recall: (text) => memory.recall(text)?.changes,
    ).call('座椅加熱打開', RepairSnapshot());
    expect(patch.changes, isEmpty);
    expect(patch.source, 'local');
  });

  test('刪除與存檔：重開後記憶還在，刪掉就沒了', () async {
    final dir = await Directory.systemTemp.createTemp('owner_memory');
    final file = File('${dir.path}/m.json');
    final a = OwnerMemory(file: file);
    await a.remember(text: '讓後座的小孩好睡一點', changes: _sleepy, source: 'cloud');
    final b = OwnerMemory(file: file);
    await b.load();
    expect(b.recall('讓後座的小孩好睡一點')?.changes, _sleepy);
    await b.forget(b.entries.single);
    final c = OwnerMemory(file: file);
    await c.load();
    expect(c.entries, isEmpty);
    expect(c.log, hasLength(1));
    await dir.delete(recursive: true);
  });

  test('連網探測：連續兩次失敗才判定離線', () async {
    final results = [true, false, true, false, false];
    var i = 0;
    final link = CloudLink(probe: () async => results[i++]);
    await link.check();
    expect(link.online, isTrue);
    await link.check();
    expect(link.online, isTrue, reason: '只失敗一次不切');
    await link.check();
    await link.check();
    expect(link.online, isTrue);
    await link.check();
    expect(link.online, isFalse);
  });
}
