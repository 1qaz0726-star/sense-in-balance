// 手動測試：電腦上跑 Hub，並提供 assets/web/ 的網頁版中控
//   flutter test test_manual/web_hub.dart  → 瀏覽器開 http://127.0.0.1:8765
// 跑 8 分鐘。情境由網頁上的控制面板操作。電腦上沒有模型，主動告知走模板。

import 'dart:io';

import 'package:cockpit_hmi/hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web hub', () async {
    Hub.I.webAsset = (p) async {
      final f = File('assets/web/$p');
      return await f.exists() ? await f.readAsBytes() : null;
    };
    Hub.I.statusExtra = () => {'model': '（電腦測試：無模型，走模板）', 'voice': '（電腦測試：無語音）', 'voice_on': true};
    await Hub.I.start();
    await Future.delayed(const Duration(minutes: 8));
    await Hub.I.stop();
  }, timeout: const Timeout(Duration(minutes: 9)));
}
