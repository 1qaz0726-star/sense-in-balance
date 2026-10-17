import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'cockpit_design.dart';
import 'protocol.dart';
import 'rules.dart' show templatePhrase;

const _safetyRed = Color(0xFFEF7669);
const _gaugeMax = 120.0;

/// An open instrument canvas displaying the original cockpit event stream.
/// The caller owns freshness; the view never manufactures vehicle signals.
class CockpitInstrumentPanel extends StatelessWidget {
  const CockpitInstrumentPanel({
    super.key,
    required this.event,
    required this.fresh,
    this.height = 380,
  });

  final Envelope? event;
  final bool fresh;
  final double height;

  @override
  Widget build(BuildContext context) {
    final available = fresh && event != null && event!.availability == Avail.ok;
    final speed = available ? event!.speed : null;
    final vehicle = available ? event!.vehicle : null;
    final rawGear = vehicle?['gear'];
    final gear = const ['P', 'R', 'N', 'D'].contains(rawGear)
        ? rawGear as String
        : null;
    final rawFuel = vehicle?['fuel_pct'];
    final fuel = rawFuel is num && rawFuel >= 0 && rawFuel <= 100
        ? rawFuel.round()
        : null;
    final turn = vehicle?['turn'];
    final blind =
        available &&
            event!.domain == 'blind_spot' &&
            event!.decision.urgency == Urgency.safety
        ? event!.state
        : null;
    final rawSide = blind?['side'];
    final side = rawSide == 'left' || rawSide == 'right'
        ? rawSide as String
        : null;
    final object = blind?['object'] is String ? blind!['object'] as String : '';

    return Semantics(
      container: true,
      label: available ? '原事件數位儀表，模擬數據' : '感知不可用，儀表數值未知',
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final horizontal = height < 280 || box.maxWidth >= 440;
                      final gauge = _GaugeWithinBounds(speed: speed);
                      final field = _VehicleField(
                        side: side,
                        object: object,
                        available: available,
                      );
                      return Column(
                        children: [
                          SizedBox(
                            height: 26,
                            child: Row(
                              children: [
                                _TurnSignal(left: true, on: turn == 'left'),
                                const SizedBox(width: 10),
                                Text(
                                  '儀表',
                                  style: cockpitText(
                                    11,
                                    color: CockpitStyle.muted,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  available ? '展示模式' : '感知不可用',
                                  style: cockpitText(
                                    11,
                                    color: available
                                        ? CockpitStyle.muted
                                        : CockpitStyle.amber,
                                    letterSpacing: .5,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                _TurnSignal(left: false, on: turn == 'right'),
                              ],
                            ),
                          ),
                          Expanded(
                            child: horizontal
                                ? Row(
                                    children: [
                                      Expanded(flex: 5, child: gauge),
                                      const SizedBox(width: 16),
                                      Expanded(flex: 6, child: field),
                                    ],
                                  )
                                : Column(
                                    children: [
                                      Expanded(flex: 5, child: gauge),
                                      Expanded(flex: 4, child: field),
                                    ],
                                  ),
                          ),
                          SizedBox(
                            height: 38,
                            child: Row(
                              children: [
                                _EventGearSelector(gear: gear),
                                const Spacer(),
                                SizedBox(
                                  width: math.min(156, box.maxWidth * .46),
                                  child: _EventFuelGauge(fuel: fuel),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (side != null)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: side == 'left' ? 0 : null,
                  right: side == 'right' ? 0 : null,
                  child: _WarningEdge(key: ValueKey(side)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A straight alert strip using the original phrase or decision.
class CockpitSafetyBanner extends StatelessWidget {
  const CockpitSafetyBanner({
    super.key,
    required this.event,
    required this.fresh,
    this.compact = false,
  });

  final Envelope? event;
  final bool fresh;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final available = fresh && event != null && event!.availability == Avail.ok;
    final urgency = available ? event!.decision.urgency : null;
    final safety = urgency == Urgency.safety;
    final color = !available
        ? CockpitStyle.amber
        : safety
        ? _safetyRed
        : urgency == Urgency.silent
        ? CockpitStyle.muted
        : CockpitStyle.accent;
    final title = !available
        ? '感知不可用'
        : switch (urgency) {
            Urgency.safety => event!.domain == 'blind_spot' ? '盲點警示' : '安全警示',
            Urgency.proactive => '座艙提示',
            Urgency.reply => '座艙回覆',
            _ => '模擬事件',
          };
    final String message;
    if (!fresh || event == null) {
      message = '感知訊號未更新';
    } else if (!available) {
      message = '感知不可用';
    } else if (urgency == Urgency.silent) {
      message = '目前沒有模擬警示';
    } else {
      final phrase = event!.phrase?.trim();
      message = phrase != null && phrase.isNotEmpty
          ? phrase
          : safety
          ? event!.decision.action
          : templatePhrase(event!.domain, event!.state, event!.decision);
    }
    final right =
        safety &&
        event!.domain == 'blind_spot' &&
        event!.state['side'] == 'right';

    return Semantics(
      container: true,
      liveRegion: safety,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: safety
              ? _safetyRed.withValues(alpha: .055)
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: safety
                  ? _safetyRed.withValues(alpha: .45)
                  : CockpitStyle.line,
            ),
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: compact ? 6 : 8,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: cockpitText(
                            12,
                            color: color,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '展示模擬',
                          style: cockpitText(
                            9,
                            color: CockpitStyle.muted,
                            letterSpacing: .4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Text(
                      message,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: cockpitText(
                        safety ? (compact ? 18 : 20) : 15,
                        color: safety ? CockpitStyle.text : color,
                        weight: safety ? FontWeight.w600 : FontWeight.w400,
                        height: 1.1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (safety || !available)
              Positioned(
                top: 0,
                bottom: 0,
                left: right ? null : 0,
                right: right ? 0 : null,
                child: Container(width: 3, color: color),
              ),
          ],
        ),
      ),
    );
  }
}

class _GaugeWithinBounds extends StatelessWidget {
  const _GaugeWithinBounds({required this.speed});
  final int? speed;

  @override
  Widget build(BuildContext context) => Center(
    child: LayoutBuilder(
      builder: (context, box) {
        final width = math.min(box.maxWidth, box.maxHeight / .88);
        return SizedBox(
          width: width,
          height: width * .88,
          child: _EventSpeedGauge(speed: speed),
        );
      },
    ),
  );
}

class _EventSpeedGauge extends StatelessWidget {
  const _EventSpeedGauge({required this.speed});
  final int? speed;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: (speed ?? 0).toDouble()),
    duration: const Duration(milliseconds: 650),
    curve: Curves.easeOutCubic,
    builder: (context, value, child) => LayoutBuilder(
      builder: (context, box) => CustomPaint(
        painter: _EventGaugePainter(value: value, available: speed != null),
        child: Align(
          alignment: const Alignment(0, -.02),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                speed == null ? '—' : '${value.round()}',
                key: const ValueKey('cockpit-speed'),
                style:
                    cockpitText(
                      box.maxWidth * .35,
                      weight: FontWeight.w300,
                      height: 1,
                    ).copyWith(
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
              ),
              const SizedBox(height: 5),
              Text(
                'km/h',
                style: cockpitText(
                  (box.maxWidth * .052).clamp(10.0, 16.0),
                  color: CockpitStyle.muted,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EventGaugePainter extends CustomPainter {
  const _EventGaugePainter({required this.value, required this.available});
  final double value;
  final bool available;
  static const _start = math.pi * 5 / 6;
  static const _sweep = math.pi * 4 / 3;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final center = Offset(radius, radius);
    final arcRadius = radius - 3;
    final rect = Rect.fromCircle(center: center, radius: arcRadius);
    Paint arc(Color color, double width) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, _start, _sweep, false, arc(CockpitStyle.line, 1));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: arcRadius - 5),
      _start,
      _sweep,
      false,
      arc(CockpitStyle.line.withValues(alpha: .35), .5),
    );
    final fraction = (value / _gaugeMax).clamp(0.0, 1.0);
    if (available && fraction > .002) {
      canvas.drawArc(
        rect,
        _start,
        _sweep * fraction,
        false,
        arc(CockpitStyle.accent, 2.2),
      );
    }
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (var tick = 0; tick <= _gaugeMax; tick += 5) {
      final angle = _start + _sweep * tick / _gaugeMax;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final major = tick % 20 == 0;
      canvas.drawLine(
        center + direction * (arcRadius - 9),
        center + direction * (arcRadius - (major ? 18 : 13)),
        Paint()
          ..color = major ? CockpitStyle.muted : CockpitStyle.line
          ..strokeWidth = major ? 1 : .7,
      );
      if (!major) continue;
      text.text = TextSpan(
        text: '$tick',
        style: cockpitText(
          (radius * .085).clamp(8.0, 13.0),
          color: CockpitStyle.muted,
          height: 1,
        ),
      );
      text.layout();
      final location = center + direction * (arcRadius - 29);
      text.paint(canvas, location - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(_EventGaugePainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.available != available;
}

class _EventGearSelector extends StatelessWidget {
  const _EventGearSelector({required this.gear});
  final String? gear;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final item in const ['P', 'R', 'N', 'D'])
        Padding(
          padding: const EdgeInsets.only(right: 13),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                item,
                style: cockpitText(
                  18,
                  color: item == gear
                      ? CockpitStyle.text
                      : CockpitStyle.muted.withValues(alpha: .45),
                  weight: item == gear ? FontWeight.w600 : FontWeight.w300,
                  height: 1,
                ),
              ),
              const SizedBox(height: 5),
              Container(
                width: 11,
                height: 1,
                color: item == gear ? CockpitStyle.accent : Colors.transparent,
              ),
            ],
          ),
        ),
      if (gear == null)
        Text('—', style: cockpitText(16, color: CockpitStyle.muted)),
    ],
  );
}

class _EventFuelGauge extends StatelessWidget {
  const _EventFuelGauge({required this.fuel});
  final int? fuel;

  @override
  Widget build(BuildContext context) {
    final low = fuel != null && fuel! < 12;
    final color = low ? CockpitStyle.amber : CockpitStyle.muted;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('燃油', style: cockpitText(10, color: color, height: 1)),
            const Spacer(),
            Text(
              fuel == null ? '—' : '$fuel%',
              key: const ValueKey('cockpit-fuel'),
              style: cockpitText(14, color: color, height: 1),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 2,
          child: CustomPaint(painter: _FuelLinePainter(fuel, color)),
        ),
      ],
    );
  }
}

class _FuelLinePainter extends CustomPainter {
  const _FuelLinePainter(this.fuel, this.color);
  final int? fuel;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      const Offset(0, 1),
      Offset(size.width, 1),
      Paint()
        ..color = CockpitStyle.line
        ..strokeWidth = 1,
    );
    if (fuel == null) return;
    canvas.drawLine(
      const Offset(0, 1),
      Offset(size.width * fuel! / 100, 1),
      Paint()
        ..color = color
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_FuelLinePainter oldDelegate) =>
      oldDelegate.fuel != fuel || oldDelegate.color != color;
}

class _TurnSignal extends StatefulWidget {
  const _TurnSignal({required this.left, required this.on});
  final bool left;
  final bool on;

  @override
  State<_TurnSignal> createState() => _TurnSignalState();
}

class _TurnSignalState extends State<_TurnSignal>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    // Eager initialization: an unlit signal may be removed before it ever
    // builds a FadeTransition. Creating its ticker in dispose is too late.
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 330),
    );
    if (widget.on) controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _TurnSignal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.on != widget.on) {
      if (widget.on) {
        controller.repeat(reverse: true);
      } else {
        controller.stop();
        controller.value = 0;
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 22,
    height: 22,
    child: widget.on
        ? Semantics(
            label: widget.left ? '左方向燈' : '右方向燈',
            child: FadeTransition(
              opacity: Tween<double>(begin: .25, end: 1).animate(controller),
              child: CustomPaint(painter: _TurnArrowPainter(widget.left)),
            ),
          )
        : null,
  );
}

class _TurnArrowPainter extends CustomPainter {
  const _TurnArrowPainter(this.left);
  final bool left;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (!left) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final p = Path()
      ..moveTo(2, 11)
      ..lineTo(10, 4)
      ..lineTo(10, 8)
      ..lineTo(20, 8)
      ..lineTo(20, 14)
      ..lineTo(10, 14)
      ..lineTo(10, 18)
      ..close();
    canvas.drawPath(p, Paint()..color = CockpitStyle.accent);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TurnArrowPainter oldDelegate) => oldDelegate.left != left;
}

class _VehicleField extends StatelessWidget {
  const _VehicleField({
    required this.side,
    required this.object,
    required this.available,
  });
  final String? side;
  final String object;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final label = side == null
        ? (available ? '模擬車輛俯視' : '感知不可用')
        : '${side == 'left' ? '左' : '右'}後方${object.isEmpty ? '物件' : object}';
    return Semantics(
      label: label,
      child: Column(
        children: [
          Expanded(
            child: CustomPaint(
              key: side == null ? null : const ValueKey('cockpit-blind-object'),
              painter: _VehicleFieldPainter(
                side: side,
                object: object,
                available: available,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          SizedBox(
            height: 22,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: cockpitText(
                side == null ? 10 : 14,
                color: side != null
                    ? _safetyRed
                    : available
                    ? CockpitStyle.muted
                    : CockpitStyle.amber,
                weight: side == null ? FontWeight.w400 : FontWeight.w600,
                letterSpacing: .4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VehicleFieldPainter extends CustomPainter {
  const _VehicleFieldPainter({
    required this.side,
    required this.object,
    required this.available,
  });
  final String? side;
  final String object;
  final bool available;

  @override
  void paint(Canvas canvas, Size size) {
    // Keep the original side/rear field, with enough lateral room for a
    // complete vehicle marker rather than compressing it into an axle glyph.
    final scale = math.min(size.width / 380, size.height / 290);
    if (scale <= 0) return;
    canvas.save();
    canvas.translate(
      (size.width - 270 * scale) / 2,
      (size.height - 290 * scale) / 2,
    );
    canvas.scale(scale);
    final opacity = available ? 1.0 : .36;
    Color metal(int hex) => Color(hex).withValues(alpha: opacity);
    Paint line(int hex, double width) => Paint()
      ..color = metal(hex)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawOval(
      const Rect.fromLTWH(80, 24, 112, 257),
      Paint()
        ..color = Colors.black.withValues(alpha: .45 * opacity)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 14),
    );
    if (side != null) {
      final left = side == 'left';
      canvas.save();
      if (!left) {
        canvas.translate(270, 0);
        canvas.scale(-1, 1);
      }
      final zone = Path()
        ..moveTo(83, 133)
        ..cubicTo(48, 144, -25, 159, -45, 194)
        ..lineTo(-45, 279)
        ..lineTo(84, 279)
        ..close();
      canvas.drawPath(
        zone,
        Paint()
          ..shader = ui.Gradient.linear(
            const Offset(82, 138),
            const Offset(-35, 278),
            [
              _safetyRed.withValues(alpha: .02),
              _safetyRed.withValues(alpha: .26),
            ],
          ),
      );
      canvas.drawPath(
        zone,
        Paint()
          ..color = _safetyRed.withValues(alpha: .7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      canvas.restore();
      _paintObject(
        canvas,
        Offset(left ? 21 : 249, 223),
        object,
        scaleFactor: (.78 / scale).clamp(1.0, 2.0),
      );
    }

    // Tyres and mirrors sit below the body, keeping the silhouette automotive.
    for (final x in [87.0, 173.0]) {
      for (final y in [77.0, 210.0]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, 10, 32),
            const Radius.circular(3),
          ),
          Paint()..color = metal(0xFF060A0C),
        );
        canvas.drawLine(
          Offset(x + 2, y + 4),
          Offset(x + 2, y + 28),
          line(0xFF465156, 1),
        );
      }
    }
    for (final x in [82.0, 177.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 106, 11, 7),
          const Radius.circular(3),
        ),
        Paint()..color = metal(0xFF65757A),
      );
    }
    final body = Path()
      ..moveTo(112, 24)
      ..cubicTo(122, 18, 148, 18, 158, 24)
      ..cubicTo(170, 35, 177, 62, 177, 92)
      ..lineTo(179, 229)
      ..cubicTo(179, 253, 164, 267, 150, 270)
      ..lineTo(120, 270)
      ..cubicTo(106, 267, 91, 253, 91, 229)
      ..lineTo(93, 92)
      ..cubicTo(93, 62, 100, 35, 112, 24)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(91, 144),
          const Offset(179, 144),
          [
            metal(0xFF40454B),
            metal(0xFF85898E),
            metal(0xFF555A62),
            metal(0xFF96999E),
            metal(0xFF41454B),
          ],
          [0, .19, .48, .80, 1],
        ),
    );
    canvas.drawPath(body, line(0xFFB3B6BA, 1.1));
    final hood = Path()
      ..moveTo(105, 70)
      ..quadraticBezierTo(135, 59, 165, 70)
      ..lineTo(157, 37)
      ..quadraticBezierTo(135, 29, 113, 37)
      ..close();
    canvas.drawPath(
      hood,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(110, 35),
          const Offset(154, 72),
          [metal(0xFF9D9FA3), metal(0xFF666B73)],
        ),
    );
    canvas.drawPath(hood, line(0xFFCAD3D5, .45));
    canvas.drawLine(
      const Offset(115, 41),
      const Offset(109, 65),
      line(0xFFBBC4C7, .65),
    );
    canvas.drawLine(
      const Offset(155, 41),
      const Offset(161, 65),
      line(0xFFBAC4C6, .65),
    );

    final windscreen = Path()
      ..moveTo(107, 78)
      ..quadraticBezierTo(135, 69, 163, 78)
      ..lineTo(169, 111)
      ..quadraticBezierTo(135, 100, 101, 111)
      ..close();
    canvas.drawPath(
      windscreen,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(104, 75),
          const Offset(166, 112),
          [metal(0xFF17232B), metal(0xFF314650), metal(0xFF0F181E)],
          [0, .5, 1],
        ),
    );
    canvas.drawPath(windscreen, line(0xFF9BAAAE, .7));
    canvas.drawLine(
      const Offset(112, 80),
      const Offset(159, 88),
      line(0xFF6F8994, .8),
    );
    final roof = Path()
      ..moveTo(107, 121)
      ..quadraticBezierTo(135, 112, 163, 121)
      ..lineTo(165, 193)
      ..quadraticBezierTo(135, 202, 105, 193)
      ..close();
    canvas.drawPath(
      roof,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(107, 150),
          const Offset(165, 160),
          [metal(0xFF6B7078), metal(0xFF8A8F96), metal(0xFF5B616B)],
          [0, .5, 1],
        ),
    );
    canvas.drawPath(roof, line(0xFFC1C2C5, .7));
    final rearGlass = Path()
      ..moveTo(104, 207)
      ..quadraticBezierTo(135, 218, 166, 207)
      ..lineTo(160, 233)
      ..quadraticBezierTo(135, 241, 110, 233)
      ..close();
    canvas.drawPath(
      rearGlass,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(105, 209),
          const Offset(165, 236),
          [metal(0xFF18262D), metal(0xFF344954), metal(0xFF111A20)],
          [0, .5, 1],
        ),
    );
    canvas.drawPath(rearGlass, line(0xFF879BA4, .65));
    for (final left in [true, false]) {
      final x = left ? 98.0 : 172.0;
      final inward = left ? 1.0 : -1.0;
      final glass = Path()
        ..moveTo(x, 111)
        ..lineTo(x + inward * 4, 120)
        ..lineTo(x + inward * 4, 195)
        ..lineTo(x, 204)
        ..close();
      canvas.drawPath(glass, Paint()..color = metal(0xFF121D23));
      canvas.drawPath(glass, line(0xFFBCC5C8, .45));
      canvas.drawLine(
        Offset(x, 154),
        Offset(x + inward * 5, 154),
        line(0xFFB5C0C3, .8),
      );
      canvas.drawLine(
        Offset(x, 194),
        Offset(x + inward * 5, 194),
        line(0xFFBCC6C8, .55),
      );
    }
    canvas.drawLine(
      const Offset(103, 248),
      const Offset(167, 248),
      line(0xFFAFBEC3, .6),
    );
    canvas.drawLine(
      const Offset(110, 256),
      const Offset(160, 256),
      line(0xFF3C4B52, 1),
    );
    // Neutral lamp details: red is reserved for an active warning.
    for (final left in [true, false]) {
      final start = left ? const Offset(105, 43) : const Offset(157, 35);
      final end = left ? const Offset(113, 35) : const Offset(165, 43);
      canvas.drawLine(start, end, line(0xFFDDE4E3, 2));
      canvas.drawLine(
        left ? const Offset(103, 258) : const Offset(154, 262),
        left ? const Offset(116, 262) : const Offset(167, 258),
        line(0xFFB9C5C9, 1.8),
      );
    }
    canvas.restore();
  }

  void _paintObject(
    Canvas canvas,
    Offset center,
    String object, {
    required double scaleFactor,
  }) {
    canvas.save();
    try {
      canvas.translate(center.dx, center.dy);
      canvas.scale(scaleFactor);
      const paleMetal = Color(0xFFE3E2DE);
      const darkMetal = Color(0xFF64707A);
      const rubber = Color(0xFF0B0F14);
      Paint stroke(Color color, double width) => Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final bodyPaint = Paint()
        ..shader = ui.Gradient.linear(
          const Offset(-24, -18),
          const Offset(24, 22),
          const [paleMetal, darkMetal],
          const [0, 1],
        );
      final redOutline = stroke(_safetyRed, 1.8);
      final highlight = stroke(paleMetal, 1.25);
      void wheel(Offset center, double radius, {bool spokes = false}) {
        canvas.drawCircle(center, radius, Paint()..color = rubber);
        canvas.drawCircle(center, radius, stroke(_safetyRed, 1.5));
        canvas.drawCircle(center, radius * .72, stroke(paleMetal, 1));
        canvas.drawCircle(center, 1.5, Paint()..color = paleMetal);
        for (var i = 0; i < (spokes ? 6 : 3); i++) {
          final angle = math.pi * 2 * i / (spokes ? 6 : 3);
          final end =
              center + Offset(math.cos(angle), math.sin(angle)) * (radius * .7);
          canvas.drawLine(center, end, stroke(darkMetal, .75));
        }
      }

      canvas.drawOval(
        const Rect.fromLTWH(-34, 24, 68, 7),
        Paint()
          ..color = Colors.black.withValues(alpha: .4)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2),
      );
      if (object == '行人' || object == 'pedestrian') {
        // Filled shoulders, jacket and separated legs distinguish a person
        // from the long wheel-and-frame silhouettes beside it.
        canvas.drawCircle(const Offset(0, -20), 5, bodyPaint);
        canvas.drawCircle(const Offset(0, -20), 5, redOutline);
        final jacket = Path()
          ..moveTo(-5, -12)
          ..quadraticBezierTo(0, -15, 5, -12)
          ..lineTo(7, 2)
          ..lineTo(1, 7)
          ..lineTo(-6, 4)
          ..close();
        canvas.drawPath(jacket, bodyPaint);
        canvas.drawPath(jacket, redOutline);
        final arm = Path()
          ..moveTo(-5, -9)
          ..lineTo(-11, -1)
          ..lineTo(-7, 6)
          ..moveTo(5, -9)
          ..lineTo(11, -5)
          ..lineTo(15, -8);
        canvas.drawPath(arm, stroke(_safetyRed, 3));
        canvas.drawPath(arm, stroke(paleMetal, 1));
        final legs = Path()
          ..moveTo(-3, 5)
          ..lineTo(-8, 18)
          ..lineTo(-13, 22)
          ..moveTo(2, 5)
          ..lineTo(8, 12)
          ..lineTo(6, 24);
        canvas.drawPath(legs, stroke(_safetyRed, 4));
        canvas.drawPath(legs, stroke(paleMetal, 1.2));
      } else if (object == '自行車' || object == 'bicycle') {
        // A complete side-view bicycle: two spoked rims, two frame triangles,
        // a crank, fork, saddle and curved handlebar. This preserves the
        // immediately recognisable silhouette of the original pedal_bike.
        wheel(const Offset(-20, 13), 10, spokes: true);
        wheel(const Offset(20, 13), 10, spokes: true);
        final frame = Path()
          ..moveTo(-20, 13)
          ..lineTo(-7, -6)
          ..lineTo(0, 13)
          ..close()
          ..moveTo(-7, -6)
          ..lineTo(11, -8)
          ..lineTo(20, 13)
          ..lineTo(0, 13)
          ..close();
        canvas.drawPath(frame, stroke(_safetyRed, 3.6));
        canvas.drawPath(frame, stroke(paleMetal, 1.35));
        canvas.drawLine(const Offset(-8, -9), const Offset(-7, -3), highlight);
        canvas.drawLine(
          const Offset(-13, -10),
          const Offset(-2, -10),
          stroke(paleMetal, 3),
        );
        final bar = Path()
          ..moveTo(11, -8)
          ..lineTo(10, -17)
          ..lineTo(18, -17)
          ..quadraticBezierTo(24, -17, 23, -11);
        canvas.drawPath(bar, redOutline);
        canvas.drawPath(bar, stroke(paleMetal, .9));
        canvas.drawCircle(const Offset(0, 13), 3, Paint()..color = darkMetal);
        canvas.drawCircle(const Offset(0, 13), 3, highlight);
        canvas.drawLine(const Offset(-4, 17), const Offset(4, 9), highlight);
        canvas.drawLine(const Offset(-6, 17), const Offset(-2, 17), highlight);
        canvas.drawLine(const Offset(2, 9), const Offset(6, 9), highlight);
      } else if (object == '機車' || object == 'motorcycle') {
        // Motorcycle profile: broad tyres, fuel tank, engine, seat, fork and
        // headlamp. The filled body is intentionally different from a bicycle.
        wheel(const Offset(-20, 14), 9.5);
        wheel(const Offset(20, 14), 9.5);
        final swingArm = Path()
          ..moveTo(-20, 14)
          ..lineTo(-5, 7)
          ..lineTo(3, 14)
          ..close();
        canvas.drawPath(swingArm, stroke(darkMetal, 3));
        canvas.drawPath(swingArm, highlight);
        final fairing = Path()
          ..moveTo(-24, -7)
          ..lineTo(-8, -7)
          ..quadraticBezierTo(-4, -18, 7, -12)
          ..lineTo(15, -6)
          ..lineTo(10, 3)
          ..lineTo(2, 11)
          ..lineTo(-10, 9)
          ..lineTo(-17, 1)
          ..close();
        canvas.drawPath(fairing, bodyPaint);
        canvas.drawPath(fairing, redOutline);
        final tank = Path()
          ..moveTo(-7, -7)
          ..quadraticBezierTo(-3, -17, 7, -11)
          ..lineTo(10, -5)
          ..quadraticBezierTo(2, -1, -7, -7);
        canvas.drawPath(tank, Paint()..color = paleMetal.withValues(alpha: .8));
        canvas.drawPath(tank, stroke(darkMetal, .8));
        final seat = RRect.fromRectAndRadius(
          const Rect.fromLTWH(-23, -11, 18, 5),
          const Radius.circular(2),
        );
        canvas.drawRRect(seat, Paint()..color = rubber);
        canvas.drawRRect(seat, highlight);
        final engine = RRect.fromRectAndRadius(
          const Rect.fromLTWH(-6, 2, 13, 9),
          const Radius.circular(2),
        );
        canvas.drawRRect(engine, Paint()..color = rubber);
        canvas.drawRRect(engine, stroke(paleMetal, 1));
        for (final y in [4.0, 6.5, 9.0]) {
          canvas.drawLine(Offset(-3, y), Offset(5, y), stroke(darkMetal, .7));
        }
        canvas.drawLine(
          const Offset(11, -8),
          const Offset(20, 14),
          stroke(paleMetal, 2),
        );
        canvas.drawLine(
          const Offset(15, -8),
          const Offset(24, 14),
          stroke(darkMetal, 1.5),
        );
        final bar = Path()
          ..moveTo(13, -8)
          ..lineTo(10, -19)
          ..lineTo(17, -19);
        canvas.drawPath(bar, highlight);
        canvas.drawCircle(const Offset(18, -8), 3, Paint()..color = paleMetal);
        canvas.drawCircle(const Offset(18, -8), 3, redOutline);
        canvas.drawLine(
          const Offset(-10, 17),
          const Offset(8, 18),
          stroke(darkMetal, 3),
        );
        canvas.drawLine(
          const Offset(-10, 17),
          const Offset(8, 18),
          stroke(paleMetal, .9),
        );
        canvas.drawLine(
          const Offset(-25, -4),
          const Offset(-28, -4),
          stroke(_safetyRed, 2.5),
        );
      } else {
        // Vehicle marker retains a top view matching the original own-car
        // scene, with separate tyres, glazing, bodywork and lamp details.
        for (final x in [-18.0, 14.0]) {
          for (final y in [-20.0, 15.0]) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(x, y, 4, 11),
                const Radius.circular(1),
              ),
              Paint()..color = rubber,
            );
          }
        }
        final body = Path()
          ..moveTo(-9, -31)
          ..quadraticBezierTo(0, -36, 9, -31)
          ..cubicTo(15, -24, 15, -17, 15, -9)
          ..lineTo(16, 24)
          ..quadraticBezierTo(15, 32, 8, 34)
          ..lineTo(-8, 34)
          ..quadraticBezierTo(-15, 32, -16, 24)
          ..lineTo(-15, -9)
          ..cubicTo(-15, -17, -15, -24, -9, -31)
          ..close();
        canvas.drawPath(body, bodyPaint);
        canvas.drawPath(body, redOutline);
        final frontGlass = Path()
          ..moveTo(-10, -17)
          ..quadraticBezierTo(0, -21, 10, -17)
          ..lineTo(12, -7)
          ..quadraticBezierTo(0, -11, -12, -7)
          ..close();
        canvas.drawPath(frontGlass, Paint()..color = rubber);
        canvas.drawPath(frontGlass, stroke(paleMetal, .65));
        final backGlass = Path()
          ..moveTo(-11, 18)
          ..quadraticBezierTo(0, 21, 11, 18)
          ..lineTo(8, 27)
          ..quadraticBezierTo(0, 30, -8, 27)
          ..close();
        canvas.drawPath(backGlass, Paint()..color = rubber);
        canvas.drawPath(backGlass, stroke(paleMetal, .65));
        final roof = RRect.fromRectAndRadius(
          const Rect.fromLTWH(-10, -4, 20, 19),
          const Radius.circular(3),
        );
        canvas.drawRRect(
          roof,
          Paint()..color = paleMetal.withValues(alpha: .23),
        );
        canvas.drawRRect(roof, stroke(darkMetal, .75));
        for (final left in [true, false]) {
          canvas.drawLine(
            left ? const Offset(-11, -27) : const Offset(5, -29),
            left ? const Offset(-5, -29) : const Offset(11, -27),
            stroke(paleMetal, 2),
          );
          canvas.drawLine(
            left ? const Offset(-12, 30) : const Offset(6, 32),
            left ? const Offset(-6, 32) : const Offset(12, 30),
            stroke(_safetyRed, 1.5),
          );
          canvas.drawLine(
            Offset(left ? -14 : 14, 4),
            Offset(left ? -11 : 11, 4),
            stroke(darkMetal, .7),
          );
        }
      }
    } finally {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_VehicleFieldPainter oldDelegate) =>
      oldDelegate.side != side ||
      oldDelegate.object != object ||
      oldDelegate.available != available;
}

class _WarningEdge extends StatefulWidget {
  const _WarningEdge({super.key});
  @override
  State<_WarningEdge> createState() => _WarningEdgeState();
}

class _WarningEdgeState extends State<_WarningEdge>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  )..repeat(reverse: true);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: .45, end: 1).animate(controller),
    child: Container(width: 4, color: _safetyRed),
  );
}
