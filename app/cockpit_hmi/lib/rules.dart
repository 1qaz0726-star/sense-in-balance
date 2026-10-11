// 規則引擎 —— 決定「說不說、說什麼、代價多少、多急」
//
// cabin_air 逐行移植自 研究/蒸餾工具/states.py 的 decide()，
// 門檻與字串必須跟那邊一致：SLM 的實機測試題就是用那支產的。
// SLM 不做這一步，它只負責把 decision 講成一句話。

import 'protocol.dart';

// ─── cabin_air ───────────────────────────────────────────────

String co2Label(int co2) {
  if (co2 >= 2500) return '很高';
  if (co2 >= 1500) return '高';
  if (co2 >= 800) return '偏高';
  return '正常';
}

const Map<String, String> kTrendLabel = {
  '↑↑': '快速上升',
  '↑': '上升',
  '→': '持平',
  '↓': '下降',
};

Decision decideCabin(Map<String, dynamic> s) {
  final int co2 = s['co2'];
  final int tin = s['t_in'];
  final int tout = s['t_out'];
  final String trend = s['trend'];
  final String recirc = s['recirc'];
  final bool rising = trend == '↑' || trend == '↑↑';
  final int delta = tout - tin;

  String act;
  Urgency urg;
  String why;
  if (co2 >= 2500) {
    act = '立即切換外循環';
    urg = Urgency.safety;
    why = 'CO2 $co2 已達嗜睡風險';
  } else if (co2 >= 1500 && rising) {
    act = '切換外循環';
    urg = Urgency.proactive;
    why = 'CO2 $co2 偏高且仍在上升';
  } else if (co2 >= 1500) {
    act = '切換外循環';
    urg = Urgency.proactive;
    why = 'CO2 $co2 偏高';
  } else if (co2 >= 800 && rising && recirc == '內') {
    act = '建議稍後換氣';
    urg = Urgency.proactive;
    why = 'CO2 $co2 上升中';
  } else {
    act = '維持現狀';
    urg = Urgency.silent;
    why = '各項數值正常';
  }

  // 代價：由規則引擎算，不讓 SLM 編
  var cost = '';
  if (act.endsWith('外循環') && delta.abs() >= 6) {
    final deg = (delta.abs() ~/ 2).clamp(0, 5);
    cost = '車內將${delta > 0 ? '升溫' : '降溫'}約$deg度';
  }
  if (recirc == '外' && act.endsWith('外循環')) {
    act = '維持現狀';
    urg = Urgency.silent;
    cost = '';
    why = '已經是外循環';
  }
  return Decision(action: act, urgency: urg, reason: why, cost: cost);
}

/// SLM 的輸入 —— INTERFACE.md §6，逐字照這個格式（模型是照這個格式測的）
String renderPrompt(Map<String, dynamic> s, Decision d) {
  final b = StringBuffer()
    ..write('狀態: co2=${s['co2']}${s['trend']} 車內=${s['t_in']} '
        '車外=${s['t_out']} 循環=${s['recirc']} 乘員=${s['occ']} '
        '車速=${s['speed']}\n')
    ..write('決策: ${d.action} | 原因=${d.reason}');
  if (d.cost.isNotEmpty) b.write(' | 代價=${d.cost}');
  b.write('\n緊急度: ${d.urgency.zh} | 上限: ${d.limit}字');
  return b.toString();
}

// ─── blind_spot ──────────────────────────────────────────────

String sideZh(String side) => side == 'left' ? '左' : '右';

Decision decideBlindSpot(Map<String, dynamic> s) {
  final side = sideZh('${s['side']}');
  final obj = '${s['object']}';
  // 方位、物件在三處（動作、原因、措辭）必須一致 —— 2026-10-01 UI 審查
  return Decision(
    action: '注意$side後方$obj',
    urgency: Urgency.safety,
    reason: '$side後方偵測到$obj',
  );
}

// ─── 模板 ────────────────────────────────────────────────────
//
// 三種情況用模板而不是 SLM：
//   ① 安全級：不讓 1–2 秒的生成延遲擋在警示前面，也不讓模型有機會改寫方位
//   ② 模型還沒下載／載入失敗
//   ③ 模型輸出沒通過 guard.dart 的檢查
// 模板只是把 action 講短，不加任何 action 裡沒有的東西。

String templatePhrase(String domain, Map<String, dynamic> s, Decision d) {
  if (d.urgency == Urgency.silent) return '';
  if (domain == 'blind_spot') {
    return '${sideZh('${s['side']}')}後方有${s['object']}';
  }
  switch (d.action) {
    case '已自動切換外循環':
      if (d.cost.contains('升溫')) return '已換外循環，會稍熱';
      if (d.cost.contains('降溫')) return '已換外循環，會稍涼';
      return '已換外循環';
    case '立即切換外循環':
      return '請切外循環';
    case '切換外循環':
      return '建議切換外循環';
    case '建議稍後換氣':
      return '稍後記得換氣';
  }
  return d.action;
}

// ─── 執行層（2026-10-05 決定）────────────────────────────────
//
// 換氣是系統自己做得到的事，不該叫正在開車的人去做。
// 規則引擎判定要換氣 → 系統直接切外循環 → 只有駕駛「會感覺到」（溫度會變）才告知。
// decideCabin() 不動（仍與 states.py 逐字一致），這一層接在它後面。

bool needsVentilation(Decision d) =>
    d.action.endsWith('外循環') || d.action == '建議稍後換氣';

/// 自動切換後要不要講：車內外溫差 ≥ 6 度（與 decideCabin 的代價門檻相同）才講
Decision informAuto(Decision d, Map<String, dynamic> s) {
  final int tin = s['t_in'];
  final int tout = s['t_out'];
  final delta = tout - tin;
  var cost = '';
  if (delta.abs() >= 6) {
    final deg = (delta.abs() ~/ 2).clamp(0, 5);
    cost = '車內將${delta > 0 ? '升溫' : '降溫'}約$deg度';
  }
  return Decision(
    action: '已自動切換外循環',
    urgency: cost.isEmpty ? Urgency.silent : Urgency.proactive,
    reason: d.reason,
    cost: cost,
  );
}
