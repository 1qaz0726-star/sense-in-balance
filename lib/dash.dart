// 數位儀表（手機，駕駛正前方）—— 只收事件、不載入模型
//
// 2026-10-05 改為「駕駛最小集合、只用圖示」：
//   常駐       時速（正中，大字＋240° 弧）、檔位 PRND、油量
//   有狀況才亮 方向燈、盲點（俯視車身＋偵測側紅區＋物件圖示＋該側螢幕邊緣紅條）、
//              感知異常燈（只在降級／失效時出現，正常時不佔位置）
//   不放       CO₂、溫度、任何句子 —— 語言輸出改走語音或中控
//
// 直放與橫放各有版面。長按畫面 → 連線設定。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'common.dart';
import 'link.dart';
import 'protocol.dart';

const double kGaugeMax = 120;
const Color kTurnGreen = C.ok;
const Color kAmber = C.degraded;

class DashScreen extends StatefulWidget {
  const DashScreen({super.key});
  @override
  State<DashScreen> createState() => _DashScreenState();
}

class _DashScreenState extends State<DashScreen> {
  @override
  void initState() {
    super.initState();
    // 等記住的 IP 讀完再決定要不要開連線頁（原本先判斷，有存 IP 也會跳出來）
    Link.I.start().then((_) {
      if (mounted && Link.I.host == null) _openConnect();
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
        final v = e?.vehicle ?? const <String, dynamic>{};
        final spd = e?.speed;
        final gear = v['gear'] as String?;
        final fuel = (v['fuel_pct'] as num?)?.round();
        final turn = v['turn'] as String?;
        final blind = e?.domain == 'blind_spot' ? e!.state : null;
        final side = blind?['side'] as String?;

        return Scaffold(
          backgroundColor: C.bg,
          body: GestureDetector(
            onLongPress: _openConnect,
            child: Stack(children: [
              SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(s.pad * 1.2, s.pad * 0.6, s.pad * 1.2, s.pad),
                  child: LayoutBuilder(builder: (context, box) {
                    final landscape = box.maxWidth > box.maxHeight;
                    final topRow = SizedBox(
                      height: s.cardTitle * 1.6,
                      child: Row(children: [
                        _TurnArrow(left: true, on: turn == 'left', size: s.cardTitle * 1.5),
                        const Spacer(),
                        _FaultLamp(l.lamp, size: s.cardTitle * 1.2),
                        const Spacer(),
                        _TurnArrow(left: false, on: turn == 'right', size: s.cardTitle * 1.5),
                      ]),
                    );
                    Widget gauge(double g) => SizedBox(
                          width: g,
                          height: g * 0.86,
                          child: _SpeedGauge(speed: spd),
                        );

                    if (landscape) {
                      final bsH = box.maxHeight * 0.26;
                      final g = math.min(
                          (box.maxHeight - s.cardTitle * 1.6 - bsH) / 0.86,
                          box.maxWidth * 0.40);
                      return Column(children: [
                        topRow,
                        Expanded(
                          child: Row(children: [
                            Expanded(child: Center(child: _GearSelector(gear, s: s, vertical: true))),
                            gauge(g),
                            Expanded(child: Center(child: _FuelGauge(fuel, s: s, vertical: true))),
                          ]),
                        ),
                        SizedBox(
                          height: bsH,
                          child: blind == null
                              ? null
                              : _BlindSpotView(side: side!, object: '${blind['object']}'),
                        ),
                      ]);
                    }

                    final g = math.min(box.maxWidth * 0.95, box.maxHeight * 0.44);
                    return Column(children: [
                      topRow,
                      const Spacer(flex: 2),
                      gauge(g),
                      SizedBox(height: s.gap * 1.2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [_GearSelector(gear, s: s), _FuelGauge(fuel, s: s)],
                      ),
                      const Spacer(flex: 2),
                      SizedBox(
                        height: box.maxHeight * 0.24,
                        child: blind == null
                            ? null
                            : _BlindSpotView(side: side!, object: '${blind['object']}'),
                      ),
                      const Spacer(flex: 1),
                      if (e == null)
                        Text(l.host == null ? '尚未連線・長按設定' : '與中控斷線・長按設定',
                            style: TextStyle(fontSize: s.label, color: C.textLow)),
                    ]);
                  }),
                ),
              ),
              if (side != null)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: side == 'left' ? 0 : null,
                  right: side == 'right' ? 0 : null,
                  child: const _EdgeBar(),
                ),
            ]),
          ),
        );
      },
    );
  }
}

// ─── 時速 ────────────────────────────────────────────────────

/// 240° 弧，底部開口。弧＝目前車速比例，刻度每 20 一格，數值有補間動畫。
class _SpeedGauge extends StatelessWidget {
  final int? speed;
  const _SpeedGauge({required this.speed});

  @override
  Widget build(BuildContext context) {
    final v = (speed ?? 0).toDouble();
    return TweenAnimationBuilder<double>(
      tween: Tween(end: v),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, a, _) => LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        return CustomPaint(
          painter: _GaugePainter(a, on: speed != null),
          child: Align(
            alignment: const Alignment(0, -0.05),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(speed == null ? '--' : a.round().toString(),
                  style: TextStyle(
                    fontSize: w * 0.30,
                    height: 1.0,
                    fontWeight: FontWeight.w300,
                    color: C.textHigh,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
              Text('km/h', style: TextStyle(fontSize: w * 0.065, color: C.textLow)),
            ]),
          ),
        );
      }),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double v;
  final bool on;
  _GaugePainter(this.v, {required this.on});

  static const double _start = math.pi * 5 / 6; // 150°
  static const double _sweep = math.pi * 4 / 3; // 240°

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(size.width / 2, r);
    final stroke = r * 0.07;
    final arcR = r - stroke;
    final rect = Rect.fromCircle(center: c, radius: arcR);
    Paint arc(Color col) => Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, _start, _sweep, false, arc(C.divider));
    final frac = (v / kGaugeMax).clamp(0.0, 1.0);
    if (on && frac > 0.002) {
      canvas.drawArc(rect, _start, _sweep * frac, false, arc(C.textHigh));
    }

    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var k = 0; k <= kGaugeMax; k += 20) {
      final ang = _start + _sweep * k / kGaugeMax;
      final dir = Offset(math.cos(ang), math.sin(ang));
      canvas.drawLine(
          c + dir * (arcR - stroke * 0.9),
          c + dir * (arcR - stroke * 1.9),
          Paint()
            ..color = C.textLow
            ..strokeWidth = r * 0.012);
      tp.text = TextSpan(text: '$k', style: TextStyle(fontSize: r * 0.085, color: C.textLow));
      tp.layout();
      final lp = c + dir * (arcR - stroke * 3.2);
      tp.paint(canvas, lp - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.v != v || o.on != on;
}

// ─── 檔位、油量 ──────────────────────────────────────────────

class _GearSelector extends StatelessWidget {
  final String? gear;
  final S s;
  final bool vertical;
  const _GearSelector(this.gear, {required this.s, this.vertical = false});

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final g in ['P', 'R', 'N', 'D'])
        Padding(
          padding: EdgeInsets.all(s.gap * 0.25),
          child: Text(g,
              style: TextStyle(
                fontSize: s.cardTitle * (g == gear ? 1.15 : 0.9),
                fontWeight: g == gear ? FontWeight.w600 : FontWeight.w400,
                color: g == gear ? C.textHigh : C.divider,
              )),
        ),
    ];
    return vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: items)
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: items);
  }
}

/// 油量：油槍圖示＋五格。低於 12% 轉琥珀色（低油量警示）
class _FuelGauge extends StatelessWidget {
  final int? pct;
  final S s;
  final bool vertical;
  const _FuelGauge(this.pct, {required this.s, this.vertical = false});

  @override
  Widget build(BuildContext context) {
    final p = pct ?? 0;
    final low = pct != null && p < 12;
    final col = low ? kAmber : C.textHigh;
    final filled = pct == null ? 0 : (p / 20).ceil().clamp(0, 5);
    final segL = s.cardTitle * 0.9, segT = s.cardTitle * 0.38;
    final segs = [
      for (var i = 0; i < 5; i++)
        Container(
          width: vertical ? segL : segT,
          height: vertical ? segT : segL,
          margin: EdgeInsets.all(s.gap * 0.15),
          decoration: BoxDecoration(
            color: i < filled ? col : C.divider,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
    ];
    final icon = Icon(Icons.local_gas_station, size: s.cardTitle * 1.1, color: low ? kAmber : C.textLow);
    return vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: [
            ...segs.reversed, // 直條由下往上填
            SizedBox(height: s.gap * 0.4),
            icon,
          ])
        : Row(mainAxisSize: MainAxisSize.min, children: [
            icon,
            SizedBox(width: s.gap * 0.4),
            ...segs,
          ]);
  }
}

// ─── 有狀況才亮 ──────────────────────────────────────────────

/// 方向燈：綠色，約 1.5 Hz 閃爍；沒打就不顯示
class _TurnArrow extends StatefulWidget {
  final bool left, on;
  final double size;
  const _TurnArrow({required this.left, required this.on, required this.size});
  @override
  State<_TurnArrow> createState() => _TurnArrowState();
}

class _TurnArrowState extends State<_TurnArrow> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 330))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(widget.left ? Icons.west : Icons.east,
        size: widget.size, color: kTurnGreen);
    if (!widget.on) return SizedBox(width: widget.size, height: widget.size);
    return FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: const Interval(0.3, 0.7)),
      child: icon,
    );
  }
}

/// 感知異常燈：正常時不出現（像實車的警示燈），降級琥珀、失效紅
/// 這取代原本常駐的「偵測中」標籤：沉默與失效的區分改由「失效時主動亮燈」＋3 秒逾時來保證
class _FaultLamp extends StatelessWidget {
  final Avail a;
  final double size;
  const _FaultLamp(this.a, {required this.size});
  @override
  Widget build(BuildContext context) {
    if (a == Avail.ok) return const SizedBox.shrink();
    final col = a == Avail.down ? C.safety : kAmber;
    return Icon(a == Avail.down ? Icons.sensors_off : Icons.sensors, size: size, color: col);
  }
}

/// 盲點：俯視車身，偵測側後方的扇區塗紅，物件圖示放在扇區裡
class _BlindSpotView extends StatelessWidget {
  final String side, object;
  const _BlindSpotView({required this.side, required this.object});

  IconData get _icon => switch (object) {
        '機車' => Icons.two_wheeler,
        '自行車' => Icons.pedal_bike,
        '行人' => Icons.directions_walk,
        _ => Icons.directions_car,
      };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final h = box.maxHeight;
      final carW = h * 0.42, carH = h * 0.86;
      final w = carW * 3.4;
      final left = side == 'left';
      return Center(
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(children: [
            Positioned.fill(child: CustomPaint(painter: _BlindPainter(left: left, carW: carW, carH: carH))),
            Positioned(
              left: left ? w * 0.04 : null,
              right: left ? null : w * 0.04,
              bottom: h * 0.02,
              child: Icon(_icon, size: h * 0.38, color: C.safety),
            ),
          ]),
        ),
      );
    });
  }
}

class _BlindPainter extends CustomPainter {
  final bool left;
  final double carW, carH;
  _BlindPainter({required this.left, required this.carW, required this.carH});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final top = (size.height - carH) / 2;
    final car = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - carW / 2, top, carW, carH), Radius.circular(carW * 0.3));

    // 偵測區：車身側邊中段往後延伸的梯形
    final sx = left ? -1.0 : 1.0;
    final edge = cx + sx * carW / 2;
    final zone = Path()
      ..moveTo(edge + sx * carW * 0.08, top + carH * 0.45)
      ..lineTo(edge + sx * carW * 1.05, top + carH * 0.55)
      ..lineTo(edge + sx * carW * 1.05, size.height)
      ..lineTo(edge + sx * carW * 0.08, size.height)
      ..close();
    canvas.drawPath(zone, Paint()..color = C.safety.withValues(alpha: 0.35));
    canvas.drawPath(
        zone,
        Paint()
          ..color = C.safety
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);

    // 自車：輪廓＋擋風玻璃
    canvas.drawRRect(car, Paint()..color = C.surface);
    canvas.drawRRect(
        car,
        Paint()
          ..color = C.textHigh
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    final ws = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - carW * 0.36, top + carH * 0.18, carW * 0.72, carH * 0.16),
        Radius.circular(carW * 0.08));
    canvas.drawRRect(ws, Paint()..color = C.textLow);
  }

  @override
  bool shouldRepaint(_BlindPainter o) => o.left != left || o.carW != carW;
}

/// 盲點側的螢幕邊緣紅條，2 Hz 脈動（落在 ISO 15008 危急狀況的 1–5 Hz 帶內）
class _EdgeBar extends StatefulWidget {
  const _EdgeBar();
  @override
  State<_EdgeBar> createState() => _EdgeBarState();
}

class _EdgeBarState extends State<_EdgeBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 250))
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
      opacity: Tween<double>(begin: 0.45, end: 1.0).animate(_c),
      child: Container(width: 14 * s.k, color: C.safety),
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
