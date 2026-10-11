// 中控畫面的資料來源 —— 2026-10-07 為了 iPad 網頁版中控拆出來
//
//   LocalSource  （local_source.dart）  AI Box 在同一台：平板一台全包（原本的「中控」模式）
//   RemoteSource （remote_source.dart） AI Box 在另一台：iPad 用 Safari 開網頁，連手機上的 Hub
//
// 這個檔案不能 import dart:io／模型／語音 —— 網頁版要能編譯。

import 'package:flutter/foundation.dart';

import 'protocol.dart';

abstract class CenterSource extends ChangeNotifier {
  Future<void> start();
  Future<void> stop();

  /// 每秒一則事件（INTERFACE.md 信封）
  Stream<Envelope> get events;

  /// 最近一則事件（控制面板「目前事件」）
  Envelope? get last;

  /// 狀態燈：超過 3 秒沒收到事件就是 down
  Avail get lamp;

  /// 畫面中央的提示（例如「連線中」）；null＝不顯示
  String? get hint => null;

  // ─── 情境注入與提問 ───
  void setScene(Scene s);
  void injectBlindSpot({String side = 'right', String object = '機車', int seconds = 4});
  void ask(String q);
  void dismissReply();

  // ─── 控制面板 ───
  List<String> get log;
  String get modelText;
  String get voiceText;
  bool get voiceOn;
  void setVoice(bool on);
  String get connText;
}
