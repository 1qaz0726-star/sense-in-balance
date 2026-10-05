// 數位儀表（手機，駕駛正前方）—— 只收事件、不載入模型
//
//   safety    紅底大字，全屏
//   proactive 一句話（平板措辭完成前只留狀態燈）
//   reply     不顯示（回答在中控）
//   silent    只留狀態燈與呼吸指示
//
// 長按畫面 → 連線設定。

import 'package:flutter/material.dart';

import 'common.dart';
import 'link.dart';
import 'protocol.dart';

class DashScreen extends StatefulWidget {
  const DashScreen({super.key});
  @override
  State<DashScreen> createState() => _DashScreenState();
}

class _DashScreenState extends State<DashScreen> {
  @override
  void initState() {
    super.initState();
    Link.I.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Link.I.host == null) _openConnect();
    });
  }

  @override
  void dispose() {
    Link.I.stop();
    super.dispose();
  }

  void _openConnect() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const DashConnectPage()));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Link.I,
      builder: (context, _) {
        final s = S.of(context);
        final l = Link.I;
        final e = l.stale || l.badSchema ? null : l.last;
        final u = e?.decision.urgency;
        final isSafety = u == Urgency.safety;
        final text = (e != null &&
                (u == Urgency.safety || u == Urgency.proactive) &&
                (e.phrase?.isNotEmpty ?? false))
            ? e.phrase!
            : null;
        final spd = e?.speed;

        return Scaffold(
          backgroundColor: isSafety ? C.safetyBg : C.bg,
          body: GestureDetector(
            onLongPress: _openConnect,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.all(s.pad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text(spd == null ? '--' : '$spd',
                                    style: TextStyle(
                                        fontSize: s.dashSpeed,
                                        height: 0.9,
                                        fontWeight: FontWeight.w300,
                                        color: isSafety
                                            ? Colors.white
                                            : C.textHigh)),
                                SizedBox(width: s.gap * 0.4),
                                Text('km/h',
                                    style: TextStyle(
                                        fontSize: s.label,
                                        color: isSafety
                                            ? Colors.white70
                                            : C.textLow)),
                              ]),
                        ),
                        AvailLamp(l.lamp, onAlert: isSafety),
                      ],
                    ),
                    const Spacer(),
                    // 沉默指示與警報訊息共用同一光學槽位（2026-10-01 審查）
                    if (text != null)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(text,
                            style: TextStyle(
                              fontSize: s.dashHero,
                              height: 1.15,
                              fontWeight: FontWeight.w500,
                              color: isSafety ? Colors.white : C.textHigh,
                            )),
                      )
                    else if (e != null)
                      const IdlePulse(),
                    const Spacer(),
                    if (e == null)
                      Text(
                          l.host == null
                              ? '尚未連線中控・長按設定'
                              : '與中控斷線（${l.host}）・長按設定',
                          style: TextStyle(fontSize: s.label, color: C.textLow))
                    else if (u == Urgency.silent)
                      Text('系統判斷此刻不需提示',
                          style: TextStyle(fontSize: s.label, color: C.textLow)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class DashConnectPage extends StatefulWidget {
  const DashConnectPage({super.key});
  @override
  State<DashConnectPage> createState() => _DashConnectPageState();
}

class _DashConnectPageState extends State<DashConnectPage> {
  late final TextEditingController _ip =
      TextEditingController(text: Link.I.host ?? '');

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }

  void _use(String h) {
    if (h.trim().isEmpty) return;
    Link.I.useHost(h);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('連線到中控')),
      body: ListenableBuilder(
        listenable: Link.I,
        builder: (context, _) => ListView(
          padding: EdgeInsets.all(s.pad),
          children: [
            Text('兩台裝置要連同一個 Wi-Fi（或手機連平板的熱點）。\n'
                '中控開著時會自動出現在下面；沒出現就手動輸入中控右側選單裡顯示的 IP。',
                style: TextStyle(fontSize: s.label, color: C.textLow, height: 1.5)),
            SizedBox(height: s.gap),
            Text('自動找到的中控',
                style: TextStyle(fontSize: s.cardBody, color: C.textHigh)),
            if (Link.I.discovered.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: s.gap * 0.5),
                child: Text('搜尋中…（有些手機收不到廣播，請改用手動輸入）',
                    style: TextStyle(fontSize: s.label, color: C.textLow)),
              ),
            for (final ip in Link.I.discovered)
              ListTile(
                leading: const Icon(Icons.tablet_android),
                title: Text(ip),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _use(ip),
              ),
            SizedBox(height: s.gap * 1.5),
            Text('手動輸入',
                style: TextStyle(fontSize: s.cardBody, color: C.textHigh)),
            SizedBox(height: s.gap * 0.5),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _ip,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      hintText: '例如 192.168.43.1', border: OutlineInputBorder()),
                  onSubmitted: _use,
                ),
              ),
              SizedBox(width: s.gap),
              FilledButton(onPressed: () => _use(_ip.text), child: const Text('連線')),
            ]),
            SizedBox(height: s.gap),
            Text(
                Link.I.connected
                    ? '✅ 已連線 ${Link.I.host}'
                    : (Link.I.host == null ? '尚未設定' : '連線中… ${Link.I.host}'),
                style: TextStyle(fontSize: s.label, color: C.textLow)),
          ],
        ),
      ),
    );
  }
}
