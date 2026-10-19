import 'package:cockpit_hmi/driver_voice_confirm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('說「好」類 → yes', () {
    for (final t in ['好', '好的', '可以', '確認', '確定。', '套用吧', 'OK', '沒問題', '對']) {
      expect(parseVoiceReply(t), VoiceReply.yes, reason: t);
    }
  });

  test('否定詞優先：「不好、不要套用、不確定、不是」都算 no', () {
    for (final t in [
      '不要',
      '不用了',
      '取消',
      '算了',
      '不好',
      '不要套用',
      '不確定',
      '不對',
      '不是',
    ]) {
      expect(parseVoiceReply(t), VoiceReply.no, reason: t);
    }
  });

  test('聽不懂、太長或沒聽到 → null（什麼都不做）', () {
    for (final t in [null, '', '嗯', '後座的風再大一點然後音樂也幫我開大聲']) {
      expect(parseVoiceReply(t), isNull, reason: '$t');
    }
  });

  test('同一版需求只問一次；版本、注意力或續辦狀態變了才再問', () {
    final task = {'task_id': 't', 'revision': 2};
    final a = voicePromptKey(task, {'attention_epoch': 4}, resume: false);
    expect(voicePromptKey(task, {'attention_epoch': 4}, resume: false), a);
    expect(
      voicePromptKey(task, {'attention_epoch': 5}, resume: false),
      isNot(a),
    );
    expect(
      voicePromptKey(task, {'attention_epoch': 4}, resume: true),
      isNot(a),
    );
    expect(
      voicePromptKey(
        {'task_id': 't', 'revision': 3},
        {'attention_epoch': 4},
        resume: false,
      ),
      isNot(a),
    );
  });

  test('VOICE-01：否定、還沒、疑問句都不能當成同意', () {
    for (final t in ['我還沒確認', '我沒說好', '不能套用', '別套用']) {
      expect(parseVoiceReply(t), VoiceReply.no, reason: t);
    }
    for (final t in ['這樣可以嗎', '要怎麼確認', '確認什麼', '好像怪怪的']) {
      expect(parseVoiceReply(t), isNull, reason: t);
    }
    for (final t in ['好啊', '可以喔', '要套用', '沒錯', '好喔。']) {
      expect(parseVoiceReply(t), VoiceReply.yes, reason: t);
    }
  });
}
