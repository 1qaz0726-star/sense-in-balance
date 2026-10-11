// 中控語音 —— 2026-10-06 加：畫面上那句話同時念出來，錄影才有「車子在跟你說話」的感覺
//
// 用 Android 內建 TTS，離線可用、不另外下載。說什麼完全由 Hub 決定（跟畫面同一句），
// 這裡只負責念：安全級打斷正在念的句子，其他排隊念完。
// 儀表（手機）不發聲：聲音只從一個地方出來，跟實車一樣。

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class Voice extends ChangeNotifier {
  Voice._();
  static final Voice I = Voice._();

  final _tts = FlutterTts();
  bool enabled = true;
  bool _ready = false;
  String status = '初始化中';

  Future<void> init() async {
    try {
      await _tts.awaitSpeakCompletion(false);
      await _tts.setQueueMode(1); // 排隊念，不互相蓋掉（安全級另外先 stop）
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      String? lang;
      for (final l in ['zh-TW', 'cmn-Hant-TW', 'zh-HK', 'zh-CN']) {
        final ok = await _tts.isLanguageAvailable(l);
        if (ok == true) {
          lang = l;
          break;
        }
      }
      if (lang == null) {
        status = '這台裝置沒有中文語音（設定 → 文字轉語音 安裝中文）';
      } else {
        await _tts.setLanguage(lang);
        _ready = true;
        status = '就緒（$lang）';
      }
    } catch (e) {
      status = '語音無法使用：$e';
    }
    notifyListeners();
  }

  /// urgent：安全級 —— 先停掉正在念的，立刻念這句
  Future<void> say(String text, {bool urgent = false}) async {
    if (!enabled || !_ready || text.isEmpty) return;
    try {
      if (urgent) await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  void toggle(bool on) {
    enabled = on;
    if (!on) _tts.stop();
    notifyListeners();
  }
}
