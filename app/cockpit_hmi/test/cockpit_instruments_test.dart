import 'package:cockpit_hmi/cockpit_design.dart';
import 'package:cockpit_hmi/cockpit_alert_slot.dart';
import 'package:cockpit_hmi/cockpit_instruments.dart';
import 'package:cockpit_hmi/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise the real protocol parser rather than a separate painter fixture.
Envelope _event({
  String? side,
  String object = '機車',
  Avail availability = Avail.ok,
}) => Envelope.fromJson({
  'schema': kSchema,
  'event_id': 'render_${side ?? 'normal'}_${availability.name}',
  'ts': 1791777600.0,
  'source': 'L1',
  'domain': side == null ? 'cabin_air' : 'blind_spot',
  'state': side == null
      ? {'co2': 760, 'recirc': '內', 'speed': 47}
      : {
          'side': side,
          'object': object,
          'ttc_s': null,
          'speed': 47,
          'bbox': null,
          'confidence': null,
        },
  'decision': {
    'action': side == null
        ? '維持現況'
        : '注意${side == 'left' ? '左' : '右'}後方$object',
    'urgency': side == null ? 'silent' : 'safety',
    'reason': '',
    'cost': '',
  },
  'availability': availability.name,
  'phrase': side == null ? null : '${side == 'left' ? '左' : '右'}後方有$object',
  'phrase_src': 'rule',
  'vehicle': {
    'speed': 47,
    'gear': 'D',
    'fuel_pct': 68,
    'turn': side,
    'telltales': <String>[],
  },
})!;

void main() {
  testWidgets(
    'shared instruments paint complete events across tablet and phone viewports',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      try {
        const viewports = [
          (name: 'tablet wide', size: Size(1232, 530)),
          (name: 'phone portrait', size: Size(340, 380)),
          (name: 'phone landscape 180', size: Size(650, 180)),
          (name: 'phone landscape 260', size: Size(650, 260)),
        ];
        final cases = [
          (
            name: 'normal',
            event: _event(),
            fresh: true,
            available: true,
            side: null,
            message: '目前沒有模擬警示',
          ),
          (
            name: 'left bicycle',
            event: _event(side: 'left', object: '自行車'),
            fresh: true,
            available: true,
            side: 'left',
            message: '左後方有自行車',
          ),
          (
            name: 'right motorcycle',
            event: _event(side: 'right'),
            fresh: true,
            available: true,
            side: 'right',
            message: '右後方有機車',
          ),
          (
            name: 'left car',
            event: _event(side: 'left', object: '汽車'),
            fresh: true,
            available: true,
            side: 'left',
            message: '左後方有汽車',
          ),
          (
            name: 'perception down with last warning',
            event: _event(side: 'right', availability: Avail.down),
            fresh: true,
            available: false,
            side: null,
            message: '感知不可用',
          ),
          (
            name: 'stale last warning',
            event: _event(side: 'left', object: '自行車'),
            fresh: false,
            available: false,
            side: null,
            message: '感知訊號未更新',
          ),
        ];

        for (final viewport in viewports) {
          tester.view.physicalSize = Size(
            viewport.size.width,
            viewport.size.height + 120,
          );
          for (final scenario in cases) {
            final context = '${viewport.name} / ${scenario.name}';
            await tester.pumpWidget(
              MaterialApp(
                theme: CockpitStyle.theme,
                home: Scaffold(
                  body: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CockpitSafetyBanner(
                        event: scenario.event,
                        fresh: scenario.fresh,
                      ),
                      CockpitInstrumentPanel(
                        event: scenario.event,
                        fresh: scenario.fresh,
                        height: viewport.size.height,
                      ),
                    ],
                  ),
                ),
              ),
            );
            // Paint the real vehicle gradients and finish the speed tween.
            // Warning pulses intentionally continue; pumpAndSettle would hang.
            await tester.pump(const Duration(milliseconds: 700));
            expect(tester.takeException(), isNull, reason: context);

            final speed = tester.widget<Text>(
              find.byKey(const ValueKey('cockpit-speed')),
            );
            final fuel = tester.widget<Text>(
              find.byKey(const ValueKey('cockpit-fuel')),
            );
            expect(
              speed.data,
              scenario.available ? '47' : '—',
              reason: context,
            );
            expect(
              fuel.data,
              scenario.available ? '68%' : '—',
              reason: context,
            );
            for (final gear in ['P', 'R', 'N', 'D']) {
              expect(find.text(gear), findsOneWidget, reason: context);
            }
            expect(find.text(scenario.message), findsWidgets, reason: context);

            final panel = tester.getRect(find.byType(CockpitInstrumentPanel));
            final fuelBounds = tester.getRect(
              find.byKey(const ValueKey('cockpit-fuel')),
            );
            expect(fuelBounds.bottom <= panel.bottom, isTrue, reason: context);

            if (scenario.side == null) {
              expect(
                find.byKey(const ValueKey('cockpit-blind-object')),
                findsNothing,
                reason: context,
              );
              expect(
                find.bySemanticsLabel(RegExp('方向燈')),
                findsNothing,
                reason: context,
              );
            } else {
              final direction = scenario.side == 'left' ? '左' : '右';
              expect(
                find.byKey(const ValueKey('cockpit-blind-object')),
                findsOneWidget,
                reason: context,
              );
              expect(
                find.bySemanticsLabel(RegExp('$direction方向燈')),
                findsWidgets,
                reason: context,
              );
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('alert transitions keep instrument and gauge geometry fixed', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    const viewports = [
      (name: 'tablet', size: Size(1280, 800), compact: false),
      (name: 'phone portrait', size: Size(390, 844), compact: false),
      (name: 'phone landscape', size: Size(860, 380), compact: true),
    ];
    final longNotice = Envelope.fromJson({
      ..._event().toJson(),
      'decision': {
        'action': '切換外循環',
        'urgency': 'proactive',
        'reason': '空氣狀態改變',
        'cost': '外界聲音',
      },
      'phrase': '已切換外循環，外面的聲音可能稍微增加，原有需求仍保留在主控畫面。',
    })!;
    final transitions = [
      (name: 'normal', event: _event(), fresh: true),
      (
        name: 'left bicycle',
        event: _event(side: 'left', object: '自行車'),
        fresh: true,
      ),
      (name: 'right motorcycle', event: _event(side: 'right'), fresh: true),
      (name: 'car', event: _event(side: 'left', object: '汽車'), fresh: true),
      (name: 'long proactive message', event: longNotice, fresh: true),
      (name: 'stale warning', event: _event(side: 'right'), fresh: false),
      (name: 'cleared', event: _event(), fresh: true),
    ];
    for (final viewport in viewports) {
      tester.view.physicalSize = viewport.size;
      Rect? originalPanel, originalGauge;
      double? originalSpeedFont, originalFuelBottom;
      for (final transition in transitions) {
        await tester.pumpWidget(
          MaterialApp(
            theme: CockpitStyle.theme,
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(height: viewport.compact ? 48 : 72),
                  CockpitAlertSlot(
                    event: transition.event,
                    fresh: transition.fresh,
                    compact: viewport.compact,
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (_, box) => CockpitInstrumentPanel(
                        event: transition.event,
                        fresh: transition.fresh,
                        height: box.maxHeight,
                      ),
                    ),
                  ),
                  SizedBox(height: viewport.compact ? 30 : 90),
                ],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 700));
        final reason = '${viewport.name} / ${transition.name}';
        expect(tester.takeException(), isNull, reason: reason);
        final speedFinder = find.byKey(const ValueKey('cockpit-speed'));
        final panel = tester.getRect(find.byType(CockpitInstrumentPanel));
        final gauge = tester.getRect(
          find
              .ancestor(of: speedFinder, matching: find.byType(CustomPaint))
              .first,
        );
        final font = tester.widget<Text>(speedFinder).style!.fontSize!;
        final fuelBottom = tester
            .getRect(find.byKey(const ValueKey('cockpit-fuel')))
            .bottom;
        originalPanel ??= panel;
        originalGauge ??= gauge;
        originalSpeedFont ??= font;
        originalFuelBottom ??= fuelBottom;
        expect(panel, originalPanel, reason: reason);
        expect(gauge, originalGauge, reason: reason);
        expect(font, originalSpeedFont, reason: reason);
        expect(fuelBottom, originalFuelBottom, reason: reason);
        if (transition.name == 'normal' || transition.name == 'cleared') {
          expect(
            find.byType(CockpitSafetyBanner),
            findsNothing,
            reason: reason,
          );
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
