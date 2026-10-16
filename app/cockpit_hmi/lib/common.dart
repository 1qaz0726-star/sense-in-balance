// 共用元件：色彩、尺寸、狀態燈、沉默指示
// 色彩與尺寸沿用 2026-10-01 UI 審查後的版本，對比值都量過，不要隨手改色。

import 'package:flutter/material.dart';

import 'protocol.dart';

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


/// 這句話是誰給的 —— 中控卡片上照實標出來，不藏
String srcLabel(Envelope e) {
  switch (e.phraseSrc) {
    case 'slm':
      final ms = e.phraseMs;
      return '端側模型措辭${ms == null ? '' : '・${(ms / 1000).toStringAsFixed(1)} 秒'}・離線';
    case 'template':
      return '模板（模型未就緒或輸出未通過檢查）';
    case 'rule':
      return '規則直出・安全級不經模型';
    case 'kb':
      final online = e.state['online'] == true;
      return online ? '本地知識庫' : '本地知識庫・離線作答';
    case 'cloud':
      return '雲端增強・連網作答';
  }
  return '';
}
