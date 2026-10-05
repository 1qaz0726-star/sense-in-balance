// 中控（平板）—— 地圖為底，事件只在有話要說時以浮層出現
//   左上 = 時速與狀態   右上 = 導航   底部 = 輸入列
//
// 同時是 AI Box：進這個畫面就啟動 Hub（規則引擎＋模擬訊號＋WebSocket）與 SLM。
// 右上角的小圓點打開控制面板（情境注入、模型、連線資訊、紀錄）—— 拍片時收起來就看不到。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'common.dart';
import 'hub.dart';
import 'protocol.dart';
import 'setup.dart';
import 'slm.dart';

class CenterScreen extends StatefulWidget {
  const CenterScreen({super.key});
  @override
  State<CenterScreen> createState() => _CenterScreenState();
}

class _CenterScreenState extends State<CenterScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _q = TextEditingController();
  StreamSubscription<Envelope>? _sub;
  Envelope? ev;
  Timer? _script;
  String? _scriptStep;

  @override
  void initState() {
    super.initState();
    Hub.I.start();
    _sub = Hub.I.events.listen((e) {
      if (mounted) setState(() => ev = e);
    });
    Slm.I.boot().then((_) {
      if (!mounted) return;
      if (Slm.I.phase == SlmPhase.missing) {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ModelSetupPage()));
      }
    });
  }

  @override
  void dispose() {
    _script?.cancel();
    _sub?.cancel();
    _q.dispose();
    Hub.I.stop();
    super.dispose();
  }

  // ─── 自動劇本：一個人也能拍完四個情境 ───
  void _runScript() {
    _script?.cancel();
    final steps = <(String, int, void Function())>[
      ('A 一切正常', 8, () => Hub.I.setScene(Scene.normal)),
      ('B CO₂ 上升', 20, () => Hub.I.setScene(Scene.co2Rising)),
      ('駕駛切外循環', 8, () => Hub.I.setScene(Scene.recircOut)),
      ('C 右後方機車', 8, () => Hub.I.injectBlindSpot()),
      ('D 停車問答', 0, () => Hub.I.setScene(Scene.parked)),
    ];
    var i = 0;
    void next() {
      if (i >= steps.length || !mounted) {
        setState(() => _scriptStep = null);
        return;
      }
      final (name, secs, act) = steps[i++];
      act();
      setState(() => _scriptStep = name);
      if (secs > 0) {
        _script = Timer(Duration(seconds: secs), next);
      } else {
        setState(() => _scriptStep = null);
      }
    }

    next();
  }

  void _stopScript() {
    _script?.cancel();
    setState(() => _scriptStep = null);
  }

  void _ask([String? text]) {
    final t = (text ?? _q.text).trim();
    if (t.isEmpty) return;
    FocusScope.of(context).unfocus();
    _q.clear();
    Hub.I.ask(t);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final e = ev;
    final u = e?.decision.urgency;
    final parked = (e?.speed ?? 45) == 0;

    return Scaffold(
      key: _scaffold,
      resizeToAvoidBottomInset: true,
      endDrawer: _ControlPanel(
        scriptStep: _scriptStep,
        onScript: _runScript,
        onStopScript: _stopScript,
      ),
      body: Stack(children: [
        _map(),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    C.bg.withValues(alpha: 0.75),
                    C.bg.withValues(alpha: 0.0),
                    C.bg.withValues(alpha: 0.0),
                    C.bg.withValues(alpha: 0.80),
                  ],
                  stops: const [0.0, 0.22, 0.70, 1.0],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: EdgeInsets.all(s.pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _speed(s, e),
                    const Spacer(),
                    if (!parked) Flexible(child: _nav(s)),
                  ],
                ),
                const Spacer(),
                if (e != null && u != Urgency.silent) _overlay(s, e),
                if (e != null && u != Urgency.silent) SizedBox(height: s.gap),
                if (parked && u != Urgency.reply) ...[
                  _suggestions(s),
                  SizedBox(height: s.gap * 0.6),
                ],
                _inputBar(s, parked),
              ],
            ),
          ),
        ),
        // 控制面板入口：低對比小圓點，拍片時幾乎看不到
        Positioned(
          right: 4,
          top: MediaQuery.paddingOf(context).top + 4,
          child: GestureDetector(
            onTap: () => _scaffold.currentState?.openEndDrawer(),
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _scriptStep != null ? C.degraded : C.divider,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // 圖磚：flutter_map 8 會自動快取看過的圖磚，先連網開過一次，之後飛航模式也顯示得出來
  Widget _map() => FlutterMap(
        options: const MapOptions(
          initialCenter: LatLng(22.7336, 120.2836), // 高雄
          initialZoom: 15.5,
          interactionOptions:
              InteractionOptions(flags: InteractiveFlag.none), // 行駛中不可操作
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.auohack.cockpit_hmi',
            tileBuilder: _darkTiles,
          ),
        ],
      );

  // 夜間暗色地圖：去飽和＋反相（BT.709 亮度權重），色彩只留給語意
  static const double _lu = 0.88;
  Widget _darkTiles(BuildContext c, Widget tile, TileImage img) => ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          -0.2126 * _lu, -0.7152 * _lu, -0.0722 * _lu, 0, 255 * _lu, //
          -0.2126 * _lu, -0.7152 * _lu, -0.0722 * _lu, 0, 255 * _lu, //
          -0.2126 * _lu, -0.7152 * _lu, -0.0722 * _lu, 0, 255 * _lu, //
          0, 0, 0, 1, 0,
        ]),
        child: tile,
      );

  Widget _speed(S s, Envelope? e) => Container(
        padding: EdgeInsets.symmetric(horizontal: s.pad, vertical: s.gap * 0.6),
        decoration: BoxDecoration(
          color: C.scrim,
          borderRadius: BorderRadius.circular(s.radius),
        ),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(e?.speed == null ? '--' : '${e!.speed}',
                        style: TextStyle(
                            fontSize: s.dashSpeed,
                            height: 0.95,
                            fontWeight: FontWeight.w300,
                            color: C.textHigh)),
                    SizedBox(width: s.gap * 0.4),
                    Text('km/h',
                        style: TextStyle(fontSize: s.label, color: C.textLow)),
                  ]),
              SizedBox(height: s.gap * 0.5),
              AvailLamp(e?.availability ?? Avail.down),
            ]),
      );

  Widget _nav(S s) => Container(
        padding: EdgeInsets.symmetric(horizontal: s.pad, vertical: s.gap * 0.8),
        decoration: BoxDecoration(
          color: C.scrim,
          borderRadius: BorderRadius.circular(s.radius),
        ),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.turn_right,
                    size: s.cardTitle * 1.4, color: C.textHigh),
                SizedBox(width: s.gap * 0.5),
                Flexible(
                  child: Text('大學南路',
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: s.cardTitle, color: C.textHigh)),
                ),
              ]),
              SizedBox(height: s.gap * 0.3),
              Text('400 公尺後右轉',
                  style: TextStyle(fontSize: s.cardBody, color: C.textLow)),
            ]),
      );

  /// 事件浮層：安全（紅）／主動（數值＋原因＋代價）／回答（問＋答）
  Widget _overlay(S s, Envelope e) {
    final d = e.decision;
    final isSafety = d.urgency == Urgency.safety;
    final isReply = d.urgency == Urgency.reply;
    final hi = isSafety ? Colors.white : C.textHigh;
    final lo = isSafety ? Colors.white70 : C.textLow;
    final phrase = e.phrase;

    final lines = <Widget>[];
    if (isReply) {
      lines.add(Text('問：${e.state['question'] ?? ''}',
          style: TextStyle(fontSize: s.cardBody, color: lo)));
      lines.add(SizedBox(height: s.gap * 0.4));
    }
    lines.add(Text(
        phrase == null || phrase.isEmpty ? '…' : phrase,
        style: TextStyle(
            fontSize: s.cardTitle,
            height: 1.2,
            fontWeight: FontWeight.w500,
            color: hi)));
    if (!isReply && d.reason.isNotEmpty) {
      lines.add(SizedBox(height: s.gap * 0.4));
      lines.add(Text(d.reason, style: TextStyle(fontSize: s.cardBody, color: lo)));
    }
    if (d.cost.isNotEmpty) {
      lines.add(SizedBox(height: s.gap * 0.2));
      lines.add(Text('代價：${d.cost}',
          style: TextStyle(fontSize: s.cardBody, color: lo)));
    }
    final tag = phrase == null ? '端側模型措辭中…' : srcLabel(e);
    if (tag.isNotEmpty) {
      lines.add(SizedBox(height: s.gap * 0.5));
      lines.add(Text(tag, style: TextStyle(fontSize: s.label, color: lo)));
    }

    return Container(
      padding: EdgeInsets.all(s.pad),
      decoration: BoxDecoration(
        color: isSafety ? C.safetyBg : C.scrim,
        borderRadius: BorderRadius.circular(s.radius),
        border: isSafety ? null : Border.all(color: C.divider),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: lines),
        ),
        if (isReply)
          IconButton(
            icon: Icon(Icons.close, color: C.textLow, size: s.cardBody * 1.2),
            onPressed: Hub.I.dismissReply,
          ),
      ]),
    );
  }

  static const _samples = ['冷氣濾網多久換一次？', '為什麼要換氣？', '沒有網路還能用嗎？'];

  Widget _suggestions(S s) => Wrap(
        spacing: s.gap * 0.6,
        runSpacing: s.gap * 0.6,
        children: [
          for (final q in _samples)
            ActionChip(
              label: Text(q, style: TextStyle(fontSize: s.label)),
              backgroundColor: C.scrim,
              side: const BorderSide(color: C.divider),
              onPressed: () => _ask(q),
            ),
        ],
      );

  /// 道安規則 §90 二：行駛中禁止「操作」行車輔助顯示設備 → 停車才開放文字輸入
  Widget _inputBar(S s, bool parked) => Row(children: [
        GestureDetector(
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('語音輸入尚未開放；停車後可用文字提問'))),
          child: Container(
            height: s.touchMin,
            padding: EdgeInsets.symmetric(horizontal: s.pad),
            decoration: BoxDecoration(
              color: C.scrim,
              borderRadius: BorderRadius.circular(s.radius),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.mic_none, size: s.cardBody * 1.3, color: C.textHigh),
              SizedBox(width: s.gap * 0.5),
              Text('語音',
                  style: TextStyle(fontSize: s.cardBody, color: C.textHigh)),
            ]),
          ),
        ),
        SizedBox(width: s.touchGap),
        Expanded(
          child: Container(
            height: s.touchMin,
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.symmetric(horizontal: s.pad),
            decoration: BoxDecoration(
              color: C.scrim,
              borderRadius: BorderRadius.circular(s.radius),
            ),
            child: parked
                ? Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _q,
                        style: TextStyle(fontSize: s.cardBody, color: C.textHigh),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: '輸入問題…',
                          hintStyle:
                              TextStyle(fontSize: s.cardBody, color: C.textLow),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _ask(),
                      ),
                    ),
                    GestureDetector(
                      onTap: _ask,
                      child: Icon(Icons.send,
                          size: s.cardBody * 1.3, color: C.textHigh),
                    ),
                  ])
                : Text('行駛中請使用語音',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: s.cardBody, color: C.textLow)),
          ),
        ),
      ]);
}

// ─────────────────────────────────────────────────────────────
// 控制面板（右側抽屜）—— 給操作的人看，不是給駕駛看
// ─────────────────────────────────────────────────────────────
class _ControlPanel extends StatelessWidget {
  final String? scriptStep;
  final VoidCallback onScript, onStopScript;
  const _ControlPanel(
      {required this.scriptStep,
      required this.onScript,
      required this.onStopScript});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 380,
      backgroundColor: C.surface,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([Hub.I, Slm.I]),
          builder: (context, _) {
            final h = Hub.I;
            final m = Slm.I;
            final e = h.last;
            Widget sceneBtn(String label, VoidCallback f) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: OutlinedButton(onPressed: f, child: Text(label)),
                );
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('情境注入（L1）',
                    style: TextStyle(fontSize: 16, color: C.textHigh)),
                const SizedBox(height: 8),
                if (scriptStep == null)
                  FilledButton.icon(
                    onPressed: onScript,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('自動劇本 A→B→外循環→C→D'),
                  )
                else
                  FilledButton.icon(
                    onPressed: onStopScript,
                    icon: const Icon(Icons.stop),
                    label: Text('劇本進行中：$scriptStep'),
                  ),
                const SizedBox(height: 10),
                sceneBtn('A 一切正常（CO₂ 420）', () => h.setScene(Scene.normal)),
                sceneBtn('B CO₂ 上升（內循環）', () => h.setScene(Scene.co2Rising)),
                sceneBtn('駕駛切外循環', () => h.setScene(Scene.recircOut)),
                sceneBtn('C 右後方機車（4 秒）', () => h.injectBlindSpot()),
                sceneBtn('C′ 左後方自行車（4 秒）',
                    () => h.injectBlindSpot(side: 'left', object: '自行車')),
                sceneBtn('D 停車（開放提問）', () => h.setScene(Scene.parked)),
                sceneBtn('恢復行駛', () => h.setScene(Scene.normal)),
                const Divider(height: 28),
                const Text('端側模型', style: TextStyle(fontSize: 16, color: C.textHigh)),
                const SizedBox(height: 6),
                Text(modelStatusText(m),
                    style: const TextStyle(color: C.textLow, height: 1.4)),
                const SizedBox(height: 6),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ModelSetupPage())),
                  child: const Text('模型設定／下載'),
                ),
                const Divider(height: 28),
                const Text('連線', style: TextStyle(fontSize: 16, color: C.textHigh)),
                const SizedBox(height: 6),
                Text(
                    '儀表請連：${h.myIps.isEmpty ? '（取得 IP 中…）' : h.myIps.join('、')}\n'
                    '埠號 $kWsPort・已連上 ${h.clientCount} 台'
                    '${h.serverError == null ? '' : '\n⚠️ 伺服器啟動失敗：${h.serverError}'}',
                    style: const TextStyle(color: C.textLow, height: 1.4)),
                const Divider(height: 28),
                const Text('目前事件', style: TextStyle(fontSize: 16, color: C.textHigh)),
                const SizedBox(height: 6),
                Text(
                    e == null
                        ? '—'
                        : '${e.eventId}・${e.domain}・${e.decision.urgency.zh}\n'
                            '動作：${e.decision.action}\n原因：${e.decision.reason}'
                            '${e.decision.cost.isEmpty ? '' : '\n代價：${e.decision.cost}'}'
                            '${e.domain == 'cabin_air' ? '\nCO₂ ${e.state['co2']} ${e.state['trend']}・循環 ${e.state['recirc']}' : ''}',
                    style: const TextStyle(color: C.textLow, height: 1.4)),
                const Divider(height: 28),
                const Text('紀錄', style: TextStyle(fontSize: 16, color: C.textHigh)),
                const SizedBox(height: 6),
                for (final l in h.log)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(l,
                        style: const TextStyle(
                            fontSize: 12, color: C.textLow, height: 1.3)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
