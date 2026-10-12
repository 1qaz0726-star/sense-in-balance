import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

abstract final class CockpitStyle {
  static const bg = Color(0xFF0A0C0F);
  static const panel = Color(0xFF12161B);
  static const line = Color(0xFF292E35);
  static const text = Color(0xFFF3F1EB);
  static const muted = Color(0xFF9399A2);
  static const accent = Color(0xFFD9C6A3);
  static const amber = Color(0xFFE9B96E);

  static ThemeData get theme => ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'NotoSansTC',
    scaffoldBackgroundColor: bg,
    colorScheme: const ColorScheme.dark(
      primary: accent,
      onPrimary: bg,
      surface: panel,
      onSurface: text,
      secondary: amber,
      error: Color(0xFFF0A394),
    ),
    dividerColor: line,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
        textStyle: cockpitText(17, weight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: const BorderSide(color: line),
        minimumSize: const Size(48, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: muted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      contentPadding: const EdgeInsets.symmetric(vertical: 14),
      hintStyle: cockpitText(17, color: muted),
      counterStyle: cockpitText(11, color: muted),
      enabledBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: line),
      ),
      focusedBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      disabledBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: line),
      ),
    ),
  );
}

TextStyle cockpitText(
  double size, {
  Color color = CockpitStyle.text,
  FontWeight weight = FontWeight.w400,
  double height = 1.4,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: 'NotoSansTC',
  fontSize: size,
  color: color,
  fontWeight: weight,
  fontVariations: [ui.FontVariation('wght', (weight.index + 1) * 100)],
  height: height,
  letterSpacing: letterSpacing,
);

class CockpitSurface extends StatelessWidget {
  const CockpitSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(padding: padding, child: child);
}

class CabinLevelIndicator extends StatelessWidget {
  const CabinLevelIndicator({
    super.key,
    required this.value,
    required this.max,
    this.color,
  });
  final int? value;
  final int max;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < max; i++)
        Expanded(
          child: Container(
            height: 4,
            margin: EdgeInsets.only(right: i == max - 1 ? 0 : 3),
            decoration: BoxDecoration(
              color: value != null && i < value!
                  ? (color ?? CockpitStyle.accent)
                  : CockpitStyle.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
    ],
  );
}

class CockpitClock extends StatefulWidget {
  const CockpitClock({super.key});
  @override
  State<CockpitClock> createState() => _CockpitClockState();
}

class _CockpitClockState extends State<CockpitClock> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Text(
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      style: cockpitText(16, color: CockpitStyle.muted),
    );
  }
}

/// A seat-area illustration, not a live vehicle sensor or driving view.
class CabinVehicleGraphic extends StatelessWidget {
  const CabinVehicleGraphic({
    super.key,
    this.height = 240,
    this.highlightRear = false,
  });
  final double height;
  final bool highlightRear;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '座艙俯視示意，${highlightRear ? '後座區域標示' : '車內座位'}',
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _CabinPainter(highlightRear)),
    ),
  );
}

class _CabinPainter extends CustomPainter {
  _CabinPainter(this.highlightRear);
  final bool highlightRear;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / 190, size.height / 300);
    canvas.save();
    canvas.translate(
      (size.width - 190 * scale) / 2,
      (size.height - 300 * scale) / 2,
    );
    canvas.scale(scale);
    canvas.drawOval(
      const Rect.fromLTWH(19, 31, 152, 262),
      Paint()
        ..color = CockpitStyle.accent.withValues(alpha: .045)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
    final body = Path()
      ..moveTo(55, 18)
      ..cubicTo(65, 3, 125, 3, 135, 18)
      ..cubicTo(146, 36, 151, 60, 151, 92)
      ..lineTo(153, 238)
      ..cubicTo(153, 270, 137, 289, 119, 292)
      ..lineTo(71, 292)
      ..cubicTo(53, 289, 37, 270, 37, 238)
      ..lineTo(39, 92)
      ..cubicTo(39, 60, 44, 36, 55, 18)
      ..close();
    canvas.drawShadow(body, Colors.black, 14, true);
    canvas.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(37, 0),
          const Offset(153, 0),
          const [
            Color(0xFF20252C),
            Color(0xFF727983),
            Color(0xFF30363E),
            Color(0xFF575F69),
            Color(0xFF171C23),
          ],
          const [0, .12, .32, .88, 1],
        ),
    );
    canvas.drawPath(
      body,
      Paint()
        ..color = const Color(0xFF8D969F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    final glass = Path()
      ..moveTo(59, 73)
      ..quadraticBezierTo(95, 59, 131, 73)
      ..lineTo(137, 111)
      ..quadraticBezierTo(95, 98, 53, 111)
      ..close();
    canvas.drawPath(
      glass,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(60, 65),
          const Offset(135, 113),
          const [Color(0xFF29323D), Color(0xFF0A0F16)],
        ),
    );
    canvas.drawPath(
      glass,
      Paint()
        ..color = CockpitStyle.line
        ..style = PaintingStyle.stroke,
    );
    final cabin = RRect.fromRectAndRadius(
      const Rect.fromLTWH(51, 111, 88, 131),
      const Radius.circular(12),
    );
    canvas.drawRRect(cabin, Paint()..color = const Color(0xFF0B1017));
    for (final x in [59.0, 101.0]) {
      final front = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 124, 30, 44),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        front,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(x, 124),
            Offset(x + 30, 168),
            const [Color(0xFF555A63), Color(0xFF232A34)],
          ),
      );
      canvas.drawRRect(
        front.deflate(3),
        Paint()
          ..color = const Color(0xFF747982).withValues(alpha: .5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6,
      );
      for (final seam in [135.0, 142.0, 149.0]) {
        canvas.drawLine(
          Offset(x + 7, seam),
          Offset(x + 23, seam),
          Paint()
            ..color = const Color(0xFF81868E).withValues(alpha: .3)
            ..strokeWidth = .5,
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + 7, 117, 16, 11),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0xFF656A73),
      );
      final rear = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 191, 30, 36),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        rear,
        Paint()
          ..color = highlightRear
              ? CockpitStyle.accent.withValues(alpha: .24)
              : const Color(0xFF303640),
      );
      canvas.drawRRect(
        rear,
        Paint()
          ..color = highlightRear
              ? CockpitStyle.accent
              : const Color(0xFF727984)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + 7, 184, 16, 9),
          const Radius.circular(3),
        ),
        Paint()
          ..color = highlightRear
              ? CockpitStyle.accent.withValues(alpha: .55)
              : const Color(0xFF656A73),
      );
    }
    canvas.drawLine(
      const Offset(95, 119),
      const Offset(95, 234),
      Paint()
        ..color = const Color(0xFF3B414C)
        ..strokeWidth = 3,
    );
    final wheel = Paint()
      ..color = const Color(0xFFB8BEC6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(72, 113), 7, wheel);
    for (final x in [31.0, 150.0]) {
      for (final y in [66.0, 228.0]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, 9, 30),
            const Radius.circular(3),
          ),
          Paint()..color = const Color(0xFF282D35),
        );
      }
    }
    canvas.drawLine(
      const Offset(56, 32),
      const Offset(75, 23),
      Paint()
        ..color = const Color(0xFFDEE3E9)
        ..strokeWidth = 2,
    );
    canvas.drawLine(
      const Offset(115, 23),
      const Offset(134, 32),
      Paint()
        ..color = const Color(0xFFDEE3E9)
        ..strokeWidth = 2,
    );
    canvas.drawLine(
      const Offset(52, 270),
      const Offset(69, 278),
      Paint()
        ..color = CockpitStyle.amber.withValues(alpha: .6)
        ..strokeWidth = 2,
    );
    canvas.drawLine(
      const Offset(121, 278),
      const Offset(138, 270),
      Paint()
        ..color = CockpitStyle.amber.withValues(alpha: .6)
        ..strokeWidth = 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CabinPainter oldDelegate) =>
      oldDelegate.highlightRear != highlightRear;
}
