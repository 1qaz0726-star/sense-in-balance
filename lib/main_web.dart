// 網頁版中控（iPad／任何瀏覽器）—— 2026-10-07
//
// 由手機上的 AI Box 提供：手機開「儀表＋AI Box」模式，iPad 用 Safari 開 http://<手機>:8765
// 頁面從哪裡載入，就連回哪裡的 ws://<同一台>:8765/center。
// 開發時可用 ?host=192.168.x.x&port=8765 指定。
//
// 建置：flutter build web -t lib/main_web.dart，再用 tool/pack_web.py 打包進 APK 的 assets/web/

import 'package:flutter/material.dart';

import 'center.dart';
import 'common.dart';
import 'remote_source.dart';

void main() {
  final b = Uri.base;
  final host = b.queryParameters['host'] ?? (b.host.isEmpty ? '127.0.0.1' : b.host);
  final port = int.tryParse(b.queryParameters['port'] ?? '') ??
      (b.hasPort && b.port != 0 ? b.port : 8765);
  final url = Uri(scheme: 'ws', host: host, port: port, path: '/center');
  runApp(MaterialApp(
    title: '座艙中控',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: C.bg),
    home: CenterScreen(source: RemoteSource(url)),
  ));
}
