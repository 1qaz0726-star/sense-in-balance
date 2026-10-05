// SLM 輸出的硬性檢查 —— INTERFACE.md §5 三條約束 + 字數 + 台灣用語
//
// 判準與 研究/蒸餾工具/score_phone.py 相同。任何一條沒過，就丟掉模型輸出改用模板，
// 並把原因記下來顯示在中控卡片上（不藏）。

import 'protocol.dart';

final RegExp _punct = RegExp(r'''[，。、！？；：「」（）,.!?;:"'()\s…—~～]''');

/// 字數怎麼算：不算標點與空白
String body(String s) => s.replaceAll(_punct, '');

const List<String> _rushWords = ['快', '立刻', '立即', '馬上', '趕快'];

/// 輸入裡沒有就不准出現的宣稱（實測抓到過「會影響健康」）
const List<String> _claimWords = [
  '健康', '危險', '中毒', '缺氧', '頭痛', '頭暈', '窒息', '致命', '傷害',
];

/// tw_lexicon.py 的大陸用語表（車上一句話會碰到的子集）
const List<String> _mainland = [
  '厘米', '質量', '信息', '視頻', '默認', '數據', '屏幕', '傳感器', '智能',
  '請您', '為您', '剎車', '攝像頭', '發動機', '車載', '空調器',
];

/// 常見簡體專有字。完整判定在 Python 端用 OpenCC；這裡只擋車上最常出現的。
const String _simplified = '约后气车温换环时间说这么会开关机线门风动调节设备显灯视频网络热凉为请过还进别';

class GuardResult {
  final bool ok;
  final String text; // 清理後的輸出
  final String? why; // 沒過的原因
  const GuardResult(this.ok, this.text, [this.why]);
}

GuardResult check(String raw, String prompt, Decision d) {
  var out = raw.trim();
  // 只取第一行、剝掉模型偶爾自己加的引號
  out = out.split('\n').first.trim();
  out = out.replaceAll(RegExp(r'^[「"『]+|[」"』]+$'), '').trim();

  if (d.urgency == Urgency.silent) {
    return out.contains('<silent>')
        ? const GuardResult(true, '')
        : GuardResult(false, '', '該沉默卻輸出「$out」');
  }
  if (out.isEmpty || out.contains('<silent>')) {
    return const GuardResult(false, '', '該說話卻沉默');
  }
  final n = body(out).runes.length;
  if (n > d.limit) return GuardResult(false, out, '超字數 $n/${d.limit}');

  final calm = d.action.contains('建議') || d.action.contains('稍後');
  if (calm) {
    for (final w in _rushWords) {
      if (out.contains(w)) return GuardResult(false, out, '建議級出現催促詞「$w」');
    }
  }
  for (final m in RegExp(r'\d+').allMatches(out)) {
    if (!prompt.contains(m.group(0)!)) {
      return GuardResult(false, out, '編造數字 ${m.group(0)}');
    }
  }
  for (final w in _claimWords) {
    if (out.contains(w) && !prompt.contains(w)) {
      return GuardResult(false, out, '加入輸入沒有的宣稱「$w」');
    }
  }
  for (final w in _mainland) {
    if (out.contains(w)) return GuardResult(false, out, '大陸用語「$w」');
  }
  for (final c in out.split('')) {
    if (_simplified.contains(c)) return GuardResult(false, out, '簡體字「$c」');
  }
  return GuardResult(true, out);
}
