// 座艙 HMI 原型 — 雙螢幕（數位儀表 / 中控）
//
// 事件結構依 INTERFACE.md v1.0。本版以腳本化回放取代 WebSocket，
// 目的是讓介面可被檢驗，不是功能 Demo。
//
// 2026-10-02 修正兩件事：
//   ① 原本所有尺寸寫死（照 1600×1000 平板設計），放到手機上會爆版。
//      改為依畫面短邊換算的 S.of(context) 縮放係數。
//   ② 中控重做：地圖為底，左上時速、右上導航、底部語音，其餘清空。
//      事件只在「有話要說」時以浮層出現 —— 沉默時中控就是一張乾淨的地圖。
//
// ⚠️ 語音在本版只有介面狀態，沒有後端。
// ⚠️ 圖磚來源可替換：開發期用線上圖磚看版面，離線版改接預打包圖磚
//    （離線方案見《查核_語音與導航可行性_20261001.md》）。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// ─────────────────────────────────────────────────────────────
// 色彩權杖（不隨尺寸變化）
// 對比值為 2026-10-01 實測，門檻依 ISO 15008:2017 夜間 5:1
// ─────────────────────────────────────────────────────────────
class C {
  static const bg = Color(0xFF0B0B0D);
  static const surface = Color(0xFF17171B);
  static const textHigh = Color(0xFFF2F2F4); // 對 bg 17.59:1
  static const textLow = Color(0xFF8A8A92); //  對 bg  5.74:1
  static const divider = Color(0xFF3A3A42);

  static const safety = Color(0xFFFF4D4D); // 對 surface 5.47:1
  static const safetyBg = Color(0xFFC62828); // 配白字 5.62:1
  static const ok = Color(0xFF3DD68C); // 對 bg 10.48:1
  static const degraded = Color(0xFFFFC14D); // 對 bg 12.16:1

  static const idleMark = textLow;
  static const scrim = Color(0xE60B0B0D); // 地圖上的浮層底，九成不透明
}

// ─────────────────────────────────────────────────────────────
// 尺寸：依畫面短邊縮放
//
// 基準為 420 邏輯像素短邊（一般手機直式）。
// 本係數保證同一版面在不同尺寸裝置上比例一致且不溢位；
// 實際視角仍取決於安裝距離，字高是否滿足 ISO 15008 的 12′
// 必須在真機上以實際安裝位置複量。
// ─────────────────────────────────────────────────────────────
class S {
  final double k;
  const S(this.k);

  static S of(BuildContext c) {
    final shortest = MediaQuery.sizeOf(c).shortestSide;
    final k = (shortest / 420).clamp(0.78, 1.9);
    return S(k);
  }

  double get dashHero => 46 * k;
  double get dashSpeed => 58 * k;
  double get cardTitle => 24 * k;
  double get cardBody => 18 * k;
  double get label => 14 * k;
  double get gap => 14 * k;
  double get pad => 18 * k;
  double get touchMin => (48 * k).clamp(48, 96); // Euro NCAP 觸控下限
  double get touchGap => 18 * k;
  double get radius => 12 * k;
}

// ─────────────────────────────────────────────────────────────
// 事件模型（INTERFACE.md §2）
// ─────────────────────────────────────────────────────────────
enum Urgency { safety, proactive, reply, silent }

enum Avail { ok, degraded, down }

class CockpitEvent {
  final String id;
  final String domain;
  final Urgency urgency;
  final String action;
  final String reason;
  final String cost;
  final String phrase;
  final Avail availability;
  final Map<String, String> state;

  const CockpitEvent({
    required this.id,
    required this.domain,
    required this.urgency,
    required this.action,
    this.reason = '',
    this.cost = '',
    this.phrase = '',
    this.availability = Avail.ok,
    this.state = const {},
  });
}

const List<CockpitEvent> kScript = [
  CockpitEvent(
    id: 'evt_000001',
    domain: 'cabin_air',
    urgency: Urgency.silent,
    action: '維持現狀',
    reason: '各項數值正常',
    state: {'CO2': '420 ppm'},
  ),
  CockpitEvent(
    id: 'evt_000002',
    domain: 'cabin_air',
    urgency: Urgency.proactive,
    action: '建議稍後換氣',
    reason: 'CO2 1340 上升中',
    phrase: '二氧化碳在升，等下記得換氣',
    state: {'CO2': '1340 ppm'},
  ),
  // 🔴 三處方位必須一致（2026-10-01 審查）：原本寫成右後／右後方／右側
  //    三種，駕駛會據此做出不同處置。INTERFACE.md §5 約束 1 要擴充：
  //    方位、距離、時間與動作同等不可改寫。
  CockpitEvent(
    id: 'evt_000003',
    domain: 'blind_spot',
    urgency: Urgency.safety,
    action: '注意右後方機車',
    reason: '右後方偵測到機車',
    phrase: '右後方有車',
    state: {'方位': '右後方'},
  ),
  CockpitEvent(
    id: 'evt_000004',
    domain: 'cabin_air',
    urgency: Urgency.silent,
    action: '維持現狀',
    reason: '已經是外循環',
    state: {'CO2': '2600 ppm'},
  ),
  CockpitEvent(
    id: 'evt_000005',
    domain: 'query',
    urgency: Urgency.reply,
    action: '這個我查不到，請參考車主手冊',
    reason: '本地知識庫檢索',
    phrase: '這個我查不到，請參考車主手冊',
    availability: Avail.degraded,
    state: {'提問': '冷氣濾網多久換一次？'},
  ),
];

void main() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const CockpitApp());
}

Widget _initialScreen() {
  try {
    final q = Uri.base.queryParameters;
    final m = q['mode'];
    final ev = int.tryParse(q['ev'] ?? '');
    if (m == 'dash') return DashScreen(fixedIndex: ev);
    if (m == 'center') return CenterScreen(fixedIndex: ev);
  } catch (_) {}
  return const ModePicker();
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
        home: _initialScreen(),
      );
}

// ─────────────────────────────────────────────────────────────
// 選模式：改用 Wrap，窄螢幕自動換行（原本固定 240 寬會被切掉）
// ─────────────────────────────────────────────────────────────
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
              Text('座艙 HMI 原型',
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
                  _btn(context, s, btnW, '數位儀表', '駕駛正前方',
                      const DashScreen()),
                  _btn(context, s, btnW, '中控', '中央顯示器',
                      const CenterScreen()),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _btn(BuildContext c, S s, double w, String t, String sub, Widget p) =>
      InkWell(
        onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => p)),
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

// ─────────────────────────────────────────────────────────────
mixin EventReplay<W extends StatefulWidget> on State<W> {
  int idx = 0;
  Timer? _t;
  CockpitEvent get ev => kScript[idx];

  void startReplay() {
    _t = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() => idx = (idx + 1) % kScript.length);
    });
  }

  void stepNext() => setState(() => idx = (idx + 1) % kScript.length);

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
// 可用性指示器（三態）— INTERFACE.md §7
// 標籤講「偵測」而非「系統」：紅屏上同時寫「系統正常」與「右後方有車」
// 會讓駕駛在一秒瞥視內把「正常」讀成路況正常。
// 形狀冗餘 ● ▲ ✕：紅綠對色覺異常者是同一灰階。
// ─────────────────────────────────────────────────────────────
class AvailLamp extends StatelessWidget {
  final Avail a;
  final bool onAlert;
  const AvailLamp(this.a, {super.key, this.onAlert = false});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    late Color c;
    late String label;
    late String glyph;
    switch (a) {
      case Avail.ok:
        c = C.ok;
        label = '偵測中';
        glyph = '●';
        break;
      case Avail.degraded:
        c = C.degraded;
        label = '偵測降級';
        glyph = '▲';
        break;
      case Avail.down:
        c = C.safety;
        label = '偵測停止';
        glyph = '✕';
        break;
    }
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: s.gap * 0.8, vertical: s.gap * 0.4),
      decoration: BoxDecoration(
        color: onAlert ? C.bg : C.scrim,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(glyph, style: TextStyle(fontSize: s.label, color: c, height: 1.0)),
        SizedBox(width: s.gap * 0.5),
        Text(label,
            style:
                TextStyle(fontSize: s.label, color: C.textHigh, height: 1.1)),
      ]),
    );
  }
}

/// 沉默指示器：0.3 Hz 呼吸，證明系統仍在運作。
/// ⚠️ 刻意低於 ISO 15008 §4.8.2 保留給危急狀況的 1–5 Hz 閃爍帶。
class IdlePulse extends StatefulWidget {
  const IdlePulse({super.key});
  @override
  State<IdlePulse> createState() => _IdlePulseState();
}

class _IdlePulseState extends State<IdlePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3333))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0)
          .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(width: 64 * s.k, height: 3 * s.k, color: C.idleMark),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 數位儀表（手機）
// ─────────────────────────────────────────────────────────────
class DashScreen extends StatefulWidget {
  final int? fixedIndex;
  const DashScreen({super.key, this.fixedIndex});
  @override
  State<DashScreen> createState() => _DashScreenState();
}

class _DashScreenState extends State<DashScreen> with EventReplay {
  @override
  void initState() {
    super.initState();
    if (widget.fixedIndex != null) {
      idx = widget.fixedIndex! % kScript.length;
    } else {
      startReplay();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isSafety = ev.urgency == Urgency.safety;
    final showText = ev.phrase.isNotEmpty && ev.urgency != Urgency.reply;

    return Scaffold(
      backgroundColor: isSafety ? C.safetyBg : C.bg,
      body: GestureDetector(
        onTap: stepNext,
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
                            Text('45',
                                style: TextStyle(
                                    fontSize: s.dashSpeed,
                                    height: 0.9,
                                    fontWeight: FontWeight.w300,
                                    color:
                                        isSafety ? Colors.white : C.textHigh)),
                            SizedBox(width: s.gap * 0.4),
                            Text('km/h',
                                style: TextStyle(
                                    fontSize: s.label,
                                    color: isSafety
                                        ? Colors.white70
                                        : C.textLow)),
                          ]),
                    ),
                    AvailLamp(ev.availability, onAlert: isSafety),
                  ],
                ),
                const Spacer(),
                // 沉默指示與警報訊息共用同一光學槽位，狀態切換時
                // 駕駛不需重新搜尋版面（2026-10-01 審查量測：相差 4 px）。
                if (showText)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(ev.phrase,
                        style: TextStyle(
                          fontSize: s.dashHero,
                          height: 1.15,
                          fontWeight: FontWeight.w500,
                          color: isSafety ? Colors.white : C.textHigh,
                        )),
                  )
                else
                  const IdlePulse(),
                const Spacer(),
                if (ev.urgency == Urgency.silent)
                  Text('系統判斷此刻不需提示',
                      style: TextStyle(fontSize: s.label, color: C.textLow)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 中控（平板）：地圖為底
//   左上 = 時速與狀態   右上 = 導航   底部 = 語音
//   事件只在有話要說時以浮層出現 —— 沉默時就是一張乾淨的地圖。
// ─────────────────────────────────────────────────────────────
class CenterScreen extends StatefulWidget {
  final int? fixedIndex;
  const CenterScreen({super.key, this.fixedIndex});
  @override
  State<CenterScreen> createState() => _CenterScreenState();
}

class _CenterScreenState extends State<CenterScreen> with EventReplay {
  final bool driving = true; // 道安規則 §90 二：行駛中禁止「操作」行車輔助顯示設備

  @override
  void initState() {
    super.initState();
    if (widget.fixedIndex != null) {
      idx = widget.fixedIndex! % kScript.length;
    } else {
      startReplay();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final silent = ev.urgency == Urgency.silent;

    return Scaffold(
      body: GestureDetector(
        onTap: stepNext,
        child: Stack(children: [
          _map(),
          // 上下緣加暗角，讓浮層文字在任何圖磚上都讀得到
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
                      _speed(s),
                      const Spacer(),
                      Flexible(child: _nav(s)),
                    ],
                  ),
                  const Spacer(),
                  if (!silent) _alertOverlay(s),
                  if (!silent) SizedBox(height: s.gap),
                  _voiceBar(s),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // 圖磚來源可替換：離線版改接預打包圖磚或政府開放路網
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

  // 夜間用暗色地圖：完全去飽和 ＋ 反相。
  //
  // 去飽和是刻意的 —— 地圖不帶顏色，色彩就完全保留給語意
  // （紅＝安全、綠＝偵測中、黃＝降級），與本案的配色原則一致。
  // 反相讓亮底圖磚變暗底，避免夜間刺眼。
  //
  // 係數為 ITU-R BT.709 亮度權重；末項 +255 完成反相後再壓到 0.88
  // 留一點黑階餘裕，避免整張圖貼到純黑而失去路網層次。
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

  Widget _speed(S s) => Container(
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
                    Text('45',
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
              AvailLamp(ev.availability),
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
                  child: Text('中山路',
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

  // 事件浮層：只在有話要說時出現
  Widget _alertOverlay(S s) {
    final isSafety = ev.urgency == Urgency.safety;
    return Container(
      padding: EdgeInsets.all(s.pad),
      decoration: BoxDecoration(
        color: isSafety ? C.safetyBg : C.scrim,
        borderRadius: BorderRadius.circular(s.radius),
        border: isSafety ? null : Border.all(color: C.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ev.phrase.isEmpty ? ev.action : ev.phrase,
            style: TextStyle(
                fontSize: s.cardTitle,
                height: 1.2,
                fontWeight: FontWeight.w500,
                color: isSafety ? Colors.white : C.textHigh)),
        if (ev.reason.isNotEmpty) ...[
          SizedBox(height: s.gap * 0.4),
          Text(ev.reason,
              style: TextStyle(
                  fontSize: s.cardBody,
                  color: isSafety ? Colors.white70 : C.textLow)),
        ],
      ]),
    );
  }

  Widget _voiceBar(S s) => Row(children: [
        Container(
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
            child: Text(
              driving ? '行駛中請使用語音' : '輸入問題…',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: s.cardBody, color: C.textLow),
            ),
          ),
        ),
      ]);
}
