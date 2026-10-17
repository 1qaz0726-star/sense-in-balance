import 'dart:convert';

import 'package:cockpit_hmi/dms/dms_monitor_state.dart';
import 'package:cockpit_hmi/dms/driver_monitor_chip.dart';
import 'package:cockpit_hmi/dms/driver_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('狀態 → 送出 JSON', () {
    test('指令剛好 5 個欄位，monitor 剛好 6 個欄位', () {
      final state = DriverMonitorState()
        ..debugSet(
          attention: AttentionState.glancingAway,
          eyes: EyeState.longBlink,
          awayMs: 1800,
          closureMs: 700,
        );
      final json = dmsCommandJson(
        commandId: 'dms_1_1',
        cabinSessionId: 'cabin-1',
        state: state,
        seq: 7,
      );
      expect(json.keys.toSet(), {
        'type',
        'command_id',
        'action',
        'cabin_session_id',
        'monitor',
      });
      expect(json['type'], 'repair_command');
      expect(json['action'], 'driver_monitor');
      expect(json['cabin_session_id'], 'cabin-1');
      final monitor = json['monitor']! as Map;
      expect(monitor.keys.toSet(), {
        'seq',
        'face',
        'attention',
        'eyes',
        'away_ms',
        'closure_ms',
      });
      expect(monitor, {
        'seq': 7,
        'face': true,
        'attention': 'glancing_away',
        'eyes': 'long_blink',
        'away_ms': 1800,
        'closure_ms': 700,
      });
      // 要能直接序列化成 JSON 字串送出。
      expect(jsonDecode(jsonEncode(json)), json);
    });

    test('每個閉眼等級與分心等級都有對應的字串', () {
      const eyes = {
        EyeState.open: 'open',
        EyeState.blink: 'blink',
        EyeState.longBlink: 'long_blink',
        EyeState.microsleep: 'microsleep',
        EyeState.sleep: 'sleep',
        EyeState.unresponsive: 'unresponsive',
      };
      const attention = {
        AttentionState.forward: 'forward',
        AttentionState.glancingAway: 'glancing_away',
        AttentionState.longDistraction: 'long_distraction',
      };
      expect(eyes.length, EyeState.values.length);
      expect(attention.length, AttentionState.values.length);
      eyes.forEach((k, v) => expect(dmsEyesWire(k), v));
      attention.forEach((k, v) => expect(dmsAttentionWire(k), v));
    });

    test('看不到臉：face=false，其餘歸零', () {
      final state = _FakeMonitor()
        ..debugSet(
          attention: AttentionState.longDistraction,
          eyes: EyeState.sleep,
          awayMs: 4000,
          closureMs: 3500,
        )
        ..noFace();
      final monitor = dmsMonitorJson(state, 1);
      expect(monitor['face'], false);
      expect(monitor['attention'], 'forward');
      expect(monitor['eyes'], 'open');
      expect(monitor['away_ms'], 0);
      expect(monitor['closure_ms'], 0);
    });

    test('真實 tracker 的判讀結果能對應到送出的 JSON', () {
      final tracker = DriverStateTracker();
      final start = DateTime(2026, 10, 18, 9);
      final fake = _FakeMonitor();
      DriverState last = tracker.update(
        eyeClosure: 0.9,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        now: start,
      );
      last = tracker.update(
        eyeClosure: 0.9,
        yawDegrees: 45,
        pitchDegrees: 0,
        rollDegrees: 0,
        now: start.add(const Duration(milliseconds: 3500)),
      );
      fake.feed(last);
      final monitor = dmsMonitorJson(fake, 2);
      expect(monitor['face'], true);
      expect(monitor['eyes'], 'sleep');
      // 偏離是從第二筆才開始算，所以只有 0 毫秒。
      expect(monitor['attention'], 'glancing_away');
      expect(monitor['closure_ms'], 3500);
      expect(monitor['away_ms'], 0);
    });

    test('tracker 長時間偏離與微睡', () {
      final tracker = DriverStateTracker();
      final start = DateTime(2026, 10, 18, 9);
      DriverState? state;
      for (var ms = 0; ms <= 3200; ms += 200) {
        state = tracker.update(
          eyeClosure: 0.1,
          yawDegrees: 50,
          pitchDegrees: 0,
          rollDegrees: 0,
          now: start.add(Duration(milliseconds: ms)),
        );
      }
      final fake = _FakeMonitor()..feed(state!);
      final monitor = dmsMonitorJson(fake, 3);
      expect(monitor['attention'], 'long_distraction');
      expect(monitor['away_ms'], 3200);
      expect(monitor['eyes'], 'open');
    });
  });

  group('駕駛畫面小燈號文字', () {
    test('鏡頭未授權／未啟用／偵測中', () {
      final s = DriverMonitorState();
      expect(dmsChipText(s), '鏡頭未啟用');
      s.debugSet(status: DmsStatus.permissionDenied);
      expect(dmsChipText(s), '鏡頭未授權');
      s.debugSet(status: DmsStatus.off);
      expect(dmsChipText(s), '鏡頭未啟用');
      s.debugSet(fps: 11.6);
      expect(dmsChipText(s), '偵測中 12 fps');
      s.debugSet(fps: 12, awayMs: 1800, closureMs: 1200);
      expect(dmsChipText(s), '偵測中 12 fps · 偏離 1.8 秒 · 閉眼 1.2 秒');
    });

    testWidgets('小燈號顯示文字，狀態變更會更新', (tester) async {
      final s = DriverMonitorState()..debugSet(status: DmsStatus.off);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DriverMonitorChip(state: s)),
        ),
      );
      expect(find.text('駕駛監測：鏡頭未啟用'), findsOneWidget);
      s.debugSet(fps: 15);
      await tester.pump();
      expect(find.text('駕駛監測：偵測中 15 fps'), findsOneWidget);
    });
  });
}

/// 不開鏡頭的假監測：用 protected 的 apply 方法灌入讀數。
class _FakeMonitor extends DriverMonitorState {
  void feed(DriverState state) => applyDriverState(state);
  void noFace() => applyNoFace();
}
