// 駕駛用說的確認：確認頁出現時念出一句摘要並問「要套用嗎？」，駕駛說「好」才送出確認。
// 只是把「按確認鍵」換成「說好」：送出的仍是同一個 confirm／resume_confirm 指令，
// 主控端照常檢查身分、版本、注意力與能力；駕駛說「不要」只是不套用，需求保留。

enum VoiceReply { yes, no }

const _no = [
  '不要',
  '不用',
  '取消',
  '算了',
  '不對',
  '不好',
  '先不要',
  '不可以',
  '不行',
  '不確定',
  '不是',
];
const _yes = ['好', '可以', '確認', '確定', '套用', '對', '沒問題', 'ok', '行', '是'];

/// 否定詞優先：「不好」「不要套用」都算不要；聽不懂回 null（什麼都不做）。
VoiceReply? parseVoiceReply(String? text) {
  if (text == null) return null;
  final t = text.toLowerCase().replaceAll(RegExp(r'[\s，,。.!！?？]'), '');
  if (t.isEmpty || t.runes.length > 12) return null;
  if (_no.any(t.contains)) return VoiceReply.no;
  if (_yes.any(t.contains)) return VoiceReply.yes;
  return null;
}

/// 同一版需求只主動問一次；版本、注意力或續辦狀態一變就可以再問。
String voicePromptKey(Map task, Map? cabinContext, {required bool resume}) =>
    '${task['task_id']}:${task['revision']}:'
    '${cabinContext?['attention_epoch']}:$resume';
