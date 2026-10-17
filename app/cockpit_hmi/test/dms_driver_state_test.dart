// DMS 判讀邏輯的單元測試
//
// 目的：在拿手機實測之前，先確認 Euro NCAP 的分級門檻真的被正確實作。
// 這樣早上測 App 時，如果分級不對，就能立刻知道是「模型看不出來」
// 而不是「我的計時邏輯寫錯」——兩者的處置完全不同。
//
// 跑法：flutter test test/driver_state_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:cockpit_hmi/dms/driver_state.dart';

void main() {
  late DriverStateTracker t;
  late DateTime t0;

  setUp(() {
    t = DriverStateTracker();
    t0 = DateTime(2026, 9, 23, 22, 0, 0);
  });

  /// 模擬以 10 fps 持續閉眼 [seconds] 秒，回傳最後一幀的狀態。
  DriverState closeEyesFor(double seconds, {double closure = 0.9}) {
    late DriverState st;
    final frames = (seconds * 10).round();
    for (int i = 0; i <= frames; i++) {
      st = t.update(
        eyeClosure: closure,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        now: t0.add(Duration(milliseconds: i * 100)),
      );
    }
    return st;
  }

  group('Euro NCAP 閉眼分級', () {
    test('睜眼 → open', () {
      final st = t.update(
        eyeClosure: 0.05,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        now: t0,
      );
      expect(st.eyeState, EyeState.open);
      expect(st.closureSeconds, 0.0);
    });

    test('閉眼 0.2 秒 → 一般眨眼', () {
      expect(closeEyesFor(0.2).eyeState, EyeState.blink);
    });

    test('閉眼 0.7 秒 → 長眨眼', () {
      expect(closeEyesFor(0.7).eyeState, EyeState.longBlink);
    });

    test('🔴 閉眼 1.5 秒 → 微睡（Euro NCAP: 1–2 秒）', () {
      final st = closeEyesFor(1.5);
      expect(st.eyeState, EyeState.microsleep);
      expect(st.closureSeconds, closeTo(1.5, 0.15));
    });

    test('🔴 閉眼 3.5 秒 → 睡著（Euro NCAP: >= 3 秒）', () {
      final st = closeEyesFor(3.5);
      expect(st.eyeState, EyeState.sleep);
      expect(st.severity2, true);
    });

    test('閉眼 6.5 秒 → 無反應（Euro NCAP: >= 6 秒）', () {
      expect(closeEyesFor(6.5).eyeState, EyeState.unresponsive);
    });

    test('🔴 這正是範例 App 做不到的：1 秒與 3 秒必須分得出來', () {
      final a = closeEyesFor(1.2);
      t.reset();
      final b = closeEyesFor(3.2);
      expect(a.eyeState, EyeState.microsleep);
      expect(b.eyeState, EyeState.sleep);
      expect(a.eyeState == b.eyeState, false,
          reason: '若兩者相同，就等於回到範例「一律顯示 Blink」的行為');
    });

    test('睜眼會重置計時，下一次閉眼從頭算', () {
      closeEyesFor(2.0); // 已達微睡
      // 睜眼一幀
      t.update(
        eyeClosure: 0.02,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        now: t0.add(const Duration(milliseconds: 2100)),
      );
      final st = t.update(
        eyeClosure: 0.9,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        now: t0.add(const Duration(milliseconds: 2200)),
      );
      expect(st.eyeState, EyeState.blink);
      expect(st.closureSeconds, closeTo(0.0, 0.05));
    });

    test('🔴 臉部消失不可被誤判為閉眼（fail-silent 防護）', () {
      closeEyesFor(2.0);
      t.onFaceLost();
      final st = t.update(
        eyeClosure: 0.9,
        yawDegrees: 0,
        pitchDegrees: 0,
        rollDegrees: 0,
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(st.eyeState, EyeState.blink,
          reason: '臉不見後重新出現，應從頭計時，不可沿用舊的閉眼起點');
    });
  });

  group('頭部姿態分心（Euro NCAP: 離開前方 3–4 秒）', () {
    DriverState lookAwayFor(double seconds, {double yaw = 45}) {
      late DriverState st;
      final frames = (seconds * 10).round();
      for (int i = 0; i <= frames; i++) {
        st = t.update(
          eyeClosure: 0.05,
          yawDegrees: yaw,
          pitchDegrees: 0,
          rollDegrees: 0,
          now: t0.add(Duration(milliseconds: i * 100)),
        );
      }
      return st;
    }

    test('面向前方 → forward', () {
      expect(lookAwayFor(5.0, yaw: 5).attentionState, AttentionState.forward);
    });

    test('偏頭 1 秒 → 短暫偏離', () {
      expect(lookAwayFor(1.0).attentionState, AttentionState.glancingAway);
    });

    test('🔴 偏頭 3.5 秒 → 長時間分心', () {
      expect(lookAwayFor(3.5).attentionState, AttentionState.longDistraction);
    });

    test('低頭（pitch）也算偏離', () {
      late DriverState st;
      for (int i = 0; i <= 40; i++) {
        st = t.update(
          eyeClosure: 0.05,
          yawDegrees: 0,
          pitchDegrees: -35,
          rollDegrees: 0,
          now: t0.add(Duration(milliseconds: i * 100)),
        );
      }
      expect(st.attentionState, AttentionState.longDistraction);
    });
  });

  group('PERCLOS 近似', () {
    test('全程睜眼 → 0%', () {
      late DriverState st;
      for (int i = 0; i < 100; i++) {
        st = t.update(
          eyeClosure: 0.05,
          yawDegrees: 0,
          pitchDegrees: 0,
          rollDegrees: 0,
          now: t0.add(Duration(milliseconds: i * 100)),
        );
      }
      expect(st.perclos, 0.0);
    });

    test('全程閉眼 → 100%', () {
      final st = closeEyesFor(5.0, closure: 0.95);
      expect(st.perclos, closeTo(1.0, 0.01));
    });

    test('一半閉一半睜 → 約 50%', () {
      late DriverState st;
      for (int i = 0; i < 100; i++) {
        st = t.update(
          eyeClosure: i.isEven ? 0.95 : 0.05,
          yawDegrees: 0,
          pitchDegrees: 0,
          rollDegrees: 0,
          now: t0.add(Duration(milliseconds: i * 100)),
        );
      }
      expect(st.perclos, closeTo(0.5, 0.02));
    });

    test('視窗未滿時會標示出來', () {
      final st = closeEyesFor(5.0);
      expect(st.perclosWindowFilled, false,
          reason: '5 秒還不到 60 秒視窗，不可宣稱為有效 PERCLOS');
    });
  });
}

/// 測試用的小工具：是否為需要警示的等級。
extension on DriverState {
  bool get severity2 => eyeState.severity == 2;
}
