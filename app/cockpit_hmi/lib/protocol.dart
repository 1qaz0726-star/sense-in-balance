// 事件信封 —— INTERFACE.md v1.0 §2–§5
//
// 2026-10-05 起 AI Box 的角色搬進中控 App（平板），信封格式不變。
// 依 §0「只准加可選欄位」加了四個欄位，舊的接收端會忽略它們：
//   phrase      這個決策的措辭（平板 SLM 產生後隨後續心跳一起廣播，取代獨立的 phrase 事件）
//   phrase_src  slm／template／kb／rule —— 句子是誰給的，要能對外講清楚
//   phrase_ms   措辭耗時（毫秒），slm 才有
//   vehicle     每則都帶的車輛基本狀態 {speed, gear, fuel_pct, turn, telltales}
//               —— 儀表常駐顯示用，不論事件是哪個 domain

const String kSchema = '1.0';

/// 情境 —— 對應影片腳本 A–D（中控與網頁版中控共用，所以放在這個不依賴 dart:io 的檔案）
enum Scene { normal, co2Rising, recircOut, parked }

String sceneName(Scene s) => const {
      Scene.normal: 'A 一切正常',
      Scene.co2Rising: 'B CO₂ 上升',
      Scene.recircOut: '手動切外循環',
      Scene.parked: 'D 停車',
    }[s]!;

enum Urgency { safety, proactive, reply, silent }

extension UrgencyX on Urgency {
  String get zh => const {
        Urgency.safety: '安全',
        Urgency.proactive: '主動告知',
        Urgency.reply: '回答',
        Urgency.silent: '不說話',
      }[this]!;

  /// 字數上限（不算標點），INTERFACE.md §5
  int get limit => const {
        Urgency.safety: 8,
        Urgency.proactive: 15,
        Urgency.reply: 30,
        Urgency.silent: 0,
      }[this]!;
}

enum Avail { ok, degraded, down }

class Decision {
  final String action;
  final Urgency urgency;
  final String reason;
  final String cost;

  const Decision({
    required this.action,
    required this.urgency,
    this.reason = '',
    this.cost = '',
  });

  int get limit => urgency.limit;

  /// 同一個「要講的事」—— 數值變動但動作不變時不重新措辭
  String get key => '${urgency.name}|$action';

  Map<String, dynamic> toJson() => {
        'action': action,
        'urgency': urgency.name,
        'limit': limit,
        'reason': reason,
        'cost': cost,
      };

  static Decision? fromJson(Object? j) {
    if (j is! Map) return null;
    final u = Urgency.values.where((e) => e.name == j['urgency']);
    if (u.isEmpty) return null;
    return Decision(
      action: '${j['action'] ?? ''}',
      urgency: u.first,
      reason: '${j['reason'] ?? ''}',
      cost: '${j['cost'] ?? ''}',
    );
  }
}

class Envelope {
  final String eventId;
  final double ts;
  final String source; // L1／L2
  final String domain; // cabin_air／blind_spot／query
  final Map<String, dynamic> state;
  final Decision decision;
  final Avail availability;
  final String? phrase;
  final String? phraseSrc;
  final int? phraseMs;
  final Map<String, dynamic>? vehicle;

  const Envelope({
    required this.eventId,
    required this.ts,
    required this.source,
    required this.domain,
    required this.state,
    required this.decision,
    this.availability = Avail.ok,
    this.phrase,
    this.phraseSrc,
    this.phraseMs,
    this.vehicle,
  });

  int? get speed {
    final v = vehicle?['speed'] ?? state['speed'];
    return v is num ? v.round() : null;
  }

  Map<String, dynamic> toJson() => {
        'schema': kSchema,
        'event_id': eventId,
        'ts': ts,
        'source': source,
        'domain': domain,
        'state': state,
        'decision': decision.toJson(),
        'availability': availability.name,
        if (phrase != null) 'phrase': phrase,
        if (phraseSrc != null) 'phrase_src': phraseSrc,
        if (phraseMs != null) 'phrase_ms': phraseMs,
        if (vehicle != null) 'vehicle': vehicle,
      };

  /// 不認得的 schema／domain／urgency 回傳 null —— 呼叫端要降級，不可以 crash（§9）
  static Envelope? fromJson(Object? j) {
    if (j is! Map) return null;
    if (j['schema'] != kSchema) return null;
    const domains = {'cabin_air', 'blind_spot', 'query'};
    if (!domains.contains(j['domain'])) return null;
    final d = Decision.fromJson(j['decision']);
    if (d == null) return null;
    final av = Avail.values.where((e) => e.name == j['availability']);
    final st = j['state'];
    return Envelope(
      eventId: '${j['event_id']}',
      ts: (j['ts'] as num?)?.toDouble() ?? 0,
      source: '${j['source']}',
      domain: '${j['domain']}',
      state: st is Map ? Map<String, dynamic>.from(st) : const {},
      decision: d,
      availability: av.isEmpty ? Avail.degraded : av.first,
      phrase: j['phrase'] as String?,
      phraseSrc: j['phrase_src'] as String?,
      phraseMs: (j['phrase_ms'] as num?)?.round(),
      vehicle: j['vehicle'] is Map ? Map<String, dynamic>.from(j['vehicle']) : null,
    );
  }
}
