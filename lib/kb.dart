// 本地知識庫 —— query 的離線回答來源（INTERFACE.md §6）
//
// 查到就直接回答原文；查不到就回固定一句「這個我查不到，請參考車主手冊」。
// 刻意「不」丟給 SLM 自由發揮：它會編。
//
// ⚠️ 這是示範用知識庫，內容是一般性的用車常識，不是任何車廠的手冊原文。
//    答案只寫各車通用的處置原則，不寫車型相依的數字。
//    正式版應換成實際車型的車主手冊。

class KbEntry {
  final List<String> keys; // 命中任一關鍵詞加重分
  final String q; // 代表問句
  final String a; // ≤30 字（不算標點）
  const KbEntry(this.keys, this.q, this.a);
}

const String kNotFound = '這個我查不到，請參考車主手冊';

const List<KbEntry> kKb = [
  KbEntry(['胎壓'], '胎壓警示燈亮了怎麼辦',
      '胎壓可能不足，請找安全的地方停車檢查'),
  KbEntry(['內循環', '外循環', '循環'], '內循環和外循環差在哪',
      '內循環不換外氣，開久了二氧化碳會累積，要定時換氣'),
  KbEntry(['二氧化碳', '換氣', 'CO2', 'co2'], '為什麼要換氣',
      '車內二氧化碳累積會讓人昏沉，定時開外循環換氣'),
  KbEntry(['水溫'], '水溫過高怎麼辦',
      '請找安全的地方停車熄火，等引擎冷卻再檢查'),
  KbEntry(['機油'], '機油燈亮了怎麼辦',
      '請找安全的地方停車熄火，不要繼續開'),
  KbEntry(['盲點', '後方有車', '紅色'], '盲點提示怎麼運作',
      '側後方偵測到來車時，儀表會變紅底並講出方位'),
  KbEntry(['不說話', '沒講話', '安靜', '沉默'], '系統為什麼都不說話',
      '數值正常時系統刻意不說話，綠燈代表仍在偵測'),
  KbEntry(['狀態燈', '綠燈', '黃燈', '燈號'], '狀態燈代表什麼',
      '綠燈偵測中，黃燈部分降級，紅燈代表畫面不可信'),
  KbEntry(['離線', '沒網路', '斷網'], '沒有網路還能用嗎',
      '可以，提示與問答都在車上運算，不需要網路'),
];

/// 問句的「殼」—— 不帶語意，算重疊時要拿掉，否則「燈亮了怎麼辦」會配到機油燈
const Set<String> _stop = {
  '怎麼', '麼辦', '了怎', '什麼', '為什', '多久', '一次', '可以', '嗎？',
  '亮了', '代表', '表什', '在哪', '差在', '還能', '能用', '用嗎',
};

Set<String> _bigrams(String s) {
  final t = s.replaceAll(RegExp(r'[^一-鿿A-Za-z0-9]'), '');
  final out = <String>{};
  for (var i = 0; i + 1 < t.length; i++) {
    out.add(t.substring(i, i + 2));
  }
  return out.difference(_stop);
}

/// 回傳 (答案, 有沒有命中)
(String, bool) lookup(String question) {
  final qb = _bigrams(question);
  KbEntry? best;
  var bestScore = 0.0;
  for (final e in kKb) {
    var score = 0.0;
    for (final k in e.keys) {
      if (question.contains(k)) score += 2;
    }
    final eb = _bigrams(e.q);
    if (qb.isNotEmpty && eb.isNotEmpty) {
      score += qb.intersection(eb).length / eb.length;
    }
    if (score > bestScore) {
      bestScore = score;
      best = e;
    }
  }
  // 門檻：命中關鍵詞（+2），或去掉問句殼之後雙字組重疊七成以上
  if (best == null || bestScore < 0.7) return (kNotFound, false);
  return (best.a, true);
}
