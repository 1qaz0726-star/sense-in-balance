// 本機 AI Box：Hub、模型、語音都在這台。
// 「中控」模式（平板一台全包）和「儀表＋AI Box」模式（手機背後跑 AI、iPad 開網頁當中控）共用。

import 'dart:async';

import 'package:flutter/services.dart';

import 'center_source.dart';
import 'hub.dart';
import 'protocol.dart';
import 'setup.dart';
import 'slm.dart';
import 'voice.dart';

/// 把模型、語音、網頁檔案接到 Hub 上。哪個模式開 Hub 都先呼叫這個。
void wireAppToHub() {
  Hub.I.onSpeak = (t, urgent) => Voice.I.say(t, urgent: urgent);
  Hub.I.statusExtra = () => {
        'model': modelStatusText(Slm.I),
        'voice': Voice.I.status,
        'voice_on': Voice.I.enabled,
      };
  Hub.I.onCommand = (m) {
    if (m['cmd'] == 'voice') Voice.I.toggle(m['on'] == true);
  };
  Hub.I.webAsset = _bundleAsset;
}

void unwireAppFromHub() {
  Hub.I.onSpeak = null;
  Hub.I.statusExtra = null;
  Hub.I.onCommand = null;
  Hub.I.webAsset = null;
}

/// 網頁版中控的檔案打包在 APK 的 assets/web/（tool/pack_web.py 產生）
Future<List<int>?> _bundleAsset(String path) async {
  try {
    final d = await rootBundle.load('assets/web/$path');
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  } catch (_) {
    return null;
  }
}

/// 啟動本機 AI Box（Hub＋語音＋模型）
Future<void> startLocalBox() async {
  wireAppToHub();
  unawaited(Voice.I.init());
  await Hub.I.start();
  await Slm.I.boot();
}

Future<void> stopLocalBox() async {
  unwireAppFromHub();
  await Hub.I.stop();
}

class LocalSource extends CenterSource {
  LocalSource() {
    Hub.I.addListener(notifyListeners);
    Slm.I.addListener(notifyListeners);
    Voice.I.addListener(notifyListeners);
  }

  @override
  Future<void> start() => startLocalBox();

  @override
  Future<void> stop() async {
    Hub.I.removeListener(notifyListeners);
    Slm.I.removeListener(notifyListeners);
    Voice.I.removeListener(notifyListeners);
    await stopLocalBox();
  }

  @override
  Stream<Envelope> get events => Hub.I.events;
  @override
  Envelope? get last => Hub.I.last;
  @override
  Avail get lamp => Hub.I.last?.availability ?? Avail.down;

  @override
  void setScene(Scene s) => Hub.I.setScene(s);
  @override
  void injectBlindSpot({String side = 'right', String object = '機車', int seconds = 4}) =>
      Hub.I.injectBlindSpot(side: side, object: object, seconds: seconds);
  @override
  void ask(String q) => Hub.I.ask(q);
  @override
  void dismissReply() => Hub.I.dismissReply();

  @override
  List<String> get log => Hub.I.log;
  @override
  String get modelText => modelStatusText(Slm.I);
  @override
  String get voiceText => Voice.I.status;
  @override
  bool get voiceOn => Voice.I.enabled;
  @override
  void setVoice(bool on) => Voice.I.toggle(on);
  @override
  String get connText {
    final h = Hub.I;
    return '儀表請連：${h.myIps.isEmpty ? '（取得 IP 中…）' : h.myIps.join('、')}\n'
        '埠號 $kWsPort・儀表 ${h.clientCount} 台・網頁中控 ${h.centerCount} 台'
        '${h.serverError == null ? '' : '\n⚠️ 伺服器啟動失敗：${h.serverError}'}';
  }
}
