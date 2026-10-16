// 車主記憶：雲端教一次、駕駛確認過，之後斷網也記得。資料只存在車上（這台裝置）。
//
// 分層借用 agent 長期記憶的做法（L0 原始紀錄 → L1 確認過的對應；L2 情境、L3 車主輪廓是後續）：
// - L0：每一句被駕駛確認並完成的需求，原話與結果都留下，可以追回原話。
// - L1：「這句話 → 這組調整」，只收駕駛確認過、而且當初是雲端解讀的句子。
// 記憶只產生「候選」，仍要駕駛確認；車主可以檢視、刪除任何一條。
import 'dart:convert';
import 'dart:io';

import 'repair_task.dart';

class MemoryEntry {
  MemoryEntry({
    required this.phrase,
    required this.changes,
    required this.learnedAt,
    this.uses = 0,
  });

  final String phrase;
  final Map<CabinSetting, RequestedChange> changes;
  final DateTime learnedAt;
  int uses;

  Map<String, dynamic> toJson() => {
    'phrase': phrase,
    'changes': {for (final e in changes.entries) e.key.name: e.value.name},
    'learned_at': learnedAt.toIso8601String(),
    'uses': uses,
  };

  static MemoryEntry? fromJson(Map<String, dynamic> j) {
    final raw = j['changes'];
    if (raw is! Map || j['phrase'] is! String) return null;
    final changes = <CabinSetting, RequestedChange>{};
    for (final e in raw.entries) {
      final s = CabinSetting.values.where((v) => v.name == e.key);
      final c = RequestedChange.values.where((v) => v.name == e.value);
      if (s.isEmpty || c.isEmpty) return null;
      changes[s.first] = c.first;
    }
    if (changes.isEmpty) return null;
    return MemoryEntry(
      phrase: j['phrase'] as String,
      changes: changes,
      learnedAt: DateTime.tryParse('${j['learned_at']}') ?? DateTime.now(),
      uses: (j['uses'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 標點、空白、語助詞不影響比對：「讓後座的小孩好睡一點喔！」＝「讓後座的小孩好睡一點」。
String normalizePhrase(String text) => text
    .replaceAll(RegExp(r'[\s，,。．.！!？?、；;：:「」『』（）()~～…]'), '')
    .replaceAll(RegExp(r'(?:啦|喔|哦|欸|耶|吧|呢|嘛)+$'), '');

class OwnerMemory {
  OwnerMemory({this.file});

  /// null＝只在記憶體（測試用）；有值＝存成 JSON，重開 App 還在。
  final File? file;
  final List<MemoryEntry> entries = [];
  final List<Map<String, dynamic>> log = [];

  static const _maxLog = 200;

  Future<void> load() async {
    final f = file;
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      entries
        ..clear()
        ..addAll(
          (j['l1'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(MemoryEntry.fromJson)
              .whereType<MemoryEntry>(),
        );
      log
        ..clear()
        ..addAll(
          (j['l0'] as List? ?? const []).whereType<Map<String, dynamic>>(),
        );
    } catch (_) {
      // 檔案壞掉就當作沒有記憶，不讓 App 起不來。
    }
  }

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    await f.writeAsString(
      jsonEncode({
        'l1': [for (final e in entries) e.toJson()],
        'l0': log,
      }),
    );
  }

  MemoryEntry? recall(String text) {
    final key = normalizePhrase(text);
    if (key.isEmpty) return null;
    for (final e in entries) {
      if (normalizePhrase(e.phrase) == key) return e;
    }
    return null;
  }

  /// 駕駛確認並完成後呼叫。L0 一律記；L1 只收當初由雲端解讀的句子。
  Future<void> remember({
    required String text,
    required Map<CabinSetting, RequestedChange> changes,
    required String? source,
  }) async {
    final actionable = Map<CabinSetting, RequestedChange>.of(changes)
      ..removeWhere((_, v) => v == RequestedChange.remove);
    log.add({
      'at': DateTime.now().toIso8601String(),
      'text': text,
      'source': source,
      'changes': {for (final e in actionable.entries) e.key.name: e.value.name},
    });
    if (log.length > _maxLog) log.removeRange(0, log.length - _maxLog);
    if (source == 'cloud' && actionable.isNotEmpty) {
      entries.removeWhere(
        (e) => normalizePhrase(e.phrase) == normalizePhrase(text),
      );
      entries.add(
        MemoryEntry(
          phrase: text,
          changes: actionable,
          learnedAt: DateTime.now(),
        ),
      );
    } else if (source == 'memory') {
      recall(text)?.uses++;
    }
    await _save();
  }

  Future<void> forget(MemoryEntry entry) async {
    entries.remove(entry);
    await _save();
  }
}
