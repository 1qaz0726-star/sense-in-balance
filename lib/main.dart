// 座艙 HMI —— 雙螢幕（數位儀表＝手機／中控＝平板），同一支 APK 選角色
//
// 2026-10-05 起從「腳本輪播的介面原型」改成會跑的 Demo：
//   中控同時是 AI Box —— 模擬車輛訊號 → 規則引擎（rules.dart）→
//   端側 SLM 措辭（slm.dart，輸出過 guard.dart 才用）→ WebSocket 廣播給儀表。
// 事件格式依 INTERFACE.md v1.0，只加了可選欄位（見 protocol.dart）。
//
// 檔案：
//   protocol.dart 事件信封      rules.dart  規則引擎（移植 states.py）
//   guard.dart    SLM 輸出檢查  kb.dart     離線知識庫
//   slm.dart      模型下載／載入／措辭
//   hub.dart      中控內建 AI Box   link.dart  儀表端連線
//   center.dart   中控畫面          dash.dart  儀表畫面
//   setup.dart    模型設定頁        common.dart 色彩、尺寸、共用元件

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'box_dash.dart';
import 'center.dart';
import 'common.dart';
import 'dash.dart';
import 'local_source.dart';
import 'setup.dart';
import 'slm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initGemma(); // 一定要在 runApp 之前
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const CockpitApp());
}

class CockpitApp extends StatelessWidget {
  const CockpitApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '座艙 HMI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: C.bg,
        ),
        home: const ModePicker(),
      );
}

class ModePicker extends StatelessWidget {
  const ModePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final w = MediaQuery.sizeOf(context).width;
    final btnW = ((w - s.pad * 3) / 2).clamp(140.0, 260.0);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(s.pad),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('座艙 HMI',
                  style: TextStyle(
                      fontSize: 22 * s.k, color: C.textHigh, letterSpacing: 2)),
              SizedBox(height: s.gap * 0.5),
              Text('選擇這台裝置的角色',
                  style: TextStyle(fontSize: s.label, color: C.textLow)),
              SizedBox(height: s.gap * 2),
              Wrap(
                spacing: s.gap,
                runSpacing: s.gap,
                alignment: WrapAlignment.center,
                children: [
                  _btn(context, s, btnW, '數位儀表', '手機・駕駛正前方',
                      () => const DashScreen()),
                  _btn(context, s, btnW, '中控', '平板・含 AI 與模型',
                      () => CenterScreen(
                            source: LocalSource(),
                            modelSetup: () => const ModelSetupPage(),
                            onStarted: (c) {
                              if (Slm.I.phase == SlmPhase.missing) {
                                Navigator.of(c).push(MaterialPageRoute(
                                    builder: (_) => const ModelSetupPage()));
                              }
                            },
                          )),
                  _btn(context, s, btnW, '儀表＋AI Box', '手機・配 iPad 網頁中控',
                      () => const BoxDashScreen()),
                ],
              ),
              SizedBox(height: s.gap * 2),
              Text('先開中控、再開儀表；兩台連同一個 Wi-Fi。\n只有一台裝置時，開中控就能單獨展示。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: s.label, color: C.textLow, height: 1.5)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _btn(BuildContext c, S s, double w, String t, String sub,
          Widget Function() page) =>
      InkWell(
        onTap: () =>
            Navigator.of(c).push(MaterialPageRoute(builder: (_) => page())),
        child: Container(
          width: w,
          padding: EdgeInsets.symmetric(vertical: s.pad * 1.6),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(s.radius),
            border: Border.all(color: C.divider),
          ),
          child: Column(children: [
            Text(t, style: TextStyle(fontSize: s.cardTitle, color: C.textHigh)),
            SizedBox(height: s.gap * 0.4),
            Text(sub, style: TextStyle(fontSize: s.label, color: C.textLow)),
          ]),
        ),
      );
}
