// 手動測試用：在電腦上跑中控的 Hub，讓接 USB 的手機（儀表）連進來看畫面。
//   adb reverse tcp:8765 tcp:8765   → 手機連 127.0.0.1
//   flutter test test_manual/hub_server.dart
// 會循環播放各情境約 10 分鐘。電腦上沒有模型，主動告知走模板。

import 'package:cockpit_hmi/hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hub server', () async {
    await Hub.I.start();
    Future<void> w(int s) => Future.delayed(Duration(seconds: s));
    for (var round = 0; round < 6; round++) {
      Hub.I.setScene(Scene.normal);
      await w(12);
      Hub.I.setScene(Scene.co2Rising);
      await w(22);
      Hub.I.setScene(Scene.recircOut);
      await w(8);
      Hub.I.injectBlindSpot(seconds: 6);
      await w(10);
      Hub.I.injectBlindSpot(side: 'left', object: '自行車', seconds: 6);
      await w(10);
      Hub.I.setScene(Scene.parked);
      await w(10);
      await Hub.I.ask('為什麼要換氣？');
      await w(12);
    }
    await Hub.I.stop();
  }, timeout: const Timeout(Duration(minutes: 12)));
}
