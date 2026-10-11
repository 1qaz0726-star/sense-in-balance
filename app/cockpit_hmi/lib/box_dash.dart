// 儀表＋AI Box —— 2026-10-07 為了「iPad 當中控」加的模式
//
//   這台（Android 手機）：背後跑 AI Box（Hub＋模型＋語音），前面顯示數位儀表
//   iPad：Safari 開 http://<這台>:8765 → 網頁版中控（同一套畫面，指令送回這台）
//
// iPad 不能裝 APK，所以 AI 留在 Android 這台；語音也從這台發出。
// 還沒有網頁中控連上時，儀表底部會顯示 iPad 要開的網址；連上就自動隱藏（拍片時看不到）。

import 'package:flutter/material.dart';

import 'common.dart';
import 'dash.dart';
import 'hub.dart';
import 'link.dart';
import 'local_source.dart';
import 'setup.dart';
import 'slm.dart';

class BoxDashScreen extends StatefulWidget {
  const BoxDashScreen({super.key});
  @override
  State<BoxDashScreen> createState() => _BoxDashScreenState();
}

class _BoxDashScreenState extends State<BoxDashScreen> {
  @override
  void initState() {
    super.initState();
    Link.I.pinLocal(); // 要在 DashScreen 的 initState 之前
    startLocalBox().then((_) {
      if (!mounted) return;
      if (Slm.I.phase == SlmPhase.missing) {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ModelSetupPage()));
      }
    });
  }

  @override
  void dispose() {
    stopLocalBox();
    Link.I.unpin();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Stack(children: [
      const DashScreen(),
      Positioned(
        left: 0,
        right: 0,
        bottom: s.pad,
        child: ListenableBuilder(
          listenable: Hub.I,
          builder: (context, _) {
            final h = Hub.I;
            if (h.centerCount > 0) return const SizedBox.shrink();
            final ips = h.myIps;
            return Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: s.pad, vertical: s.gap * 0.6),
                decoration: BoxDecoration(
                  color: C.surface,
                  borderRadius: BorderRadius.circular(s.radius),
                  border: Border.all(color: C.divider),
                ),
                child: Text(
                  ips.isEmpty
                      ? 'AI Box 啟動中…'
                      : 'iPad 用 Safari 開：${ips.map((ip) => 'http://$ip:$kWsPort').join('  或  ')}\n'
                          '${modelStatusText(Slm.I)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: s.label, color: C.textLow, height: 1.5),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
