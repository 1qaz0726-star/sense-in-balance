// 駕駛狀態判讀（DMS）—— 閉眼時長分級 ＋ PERCLOS ＋ 頭部姿態分心
//
// 本檔案由 Claude 於 2026-09-23 撰寫，供友達智慧座艙專案驗證用。
//
// 🔴 為什麼需要這個檔案：
//   `mediapipe_face_mesh` 的範例只做了無狀態的門檻判斷——
//       if (blink > 0.45) return 'Blink';
//   所以閉眼五秒會一直顯示 "Blink"。blendshape 的 eyeBlink 是**連續值**
//   （0 = 眼睛全開，1 = 全閉），不是事件。要分出「眨眼」與「微睡」，
//   必須自己記時間。這個檔案就是那個計時器。
//
// 📏 分級門檻的出處（Euro NCAP Safe Driving – Driver Engagement Protocol
//    v1.2, July 2026, Implementation January 2026）逐字：
//      Microsleep : "short duration eye closure (1–2 seconds)"
//      Sleep      : "continued eye closure >= 3 seconds"
//      Unresponsive: "...or when the eyes have been closed for >= 6 seconds"
//      Long Distraction: 單次注視離開前方道路 3–4 秒
//
// ⚠️ 兩個必須誠實標示的近似：
//   1. PERCLOS 的學術定義是「眼瞼閉合 >= 80% 的時間佔比」，量的是**眼瞼開度**。
//      blendshape 的 eyeBlink 是模型推論出的「閉眼程度」，**不是眼瞼開度的物理量測**。
//      因此本檔案算的是 PERCLOS 的**近似值**，不可宣稱為標準 PERCLOS。
//   2. 「視線離開前方」Euro NCAP 指的是 gaze（眼球方向）。本檔案用**頭部姿態**
//      近似，抓得到 Owl（轉頭）但抓不到 Lizard（頭不動、只動眼球）。
//      Euro NCAP v1.2 明文：只有頭部追蹤而無眼動追蹤的系統會被判定為 degraded。

import 'dart:collection';

/// 駕駛的眼睛狀態，依 Euro NCAP 2026 分級。
enum EyeState {
  /// 眼睛張開。
  open,

  /// 一般眨眼（< 0.5 秒）。
  blink,

  /// 長眨眼（0.5–1.0 秒）—— 尚未達 Euro NCAP 門檻，但值得注意。
  longBlink,

  /// 微睡 —— Euro NCAP: "short duration eye closure (1–2 seconds)"。
  microsleep,

  /// 睡著 —— Euro NCAP: "continued eye closure >= 3 seconds"。
  sleep,

  /// 無反應 —— Euro NCAP: 閉眼 >= 6 秒。
  unresponsive,
}

/// 頭部姿態推得的分心狀態（⚠️ 近似，見檔頭說明）。
enum AttentionState {
  /// 面向前方。
  forward,

  /// 短暫偏離。
  glancingAway,

  /// 長時間偏離 —— Euro NCAP Long Distraction: 3–4 秒。
  longDistraction,
}

/// 一次判讀的結果。
class DriverState {
  const DriverState({
    required this.eyeState,
    required this.attentionState,
    required this.eyeClosure,
    required this.closureSeconds,
    required this.awaySeconds,
    required this.perclos,
    required this.yawDegrees,
    required this.pitchDegrees,
    required this.rollDegrees,
    required this.perclosWindowFilled,
  });

  /// 閉眼分級。
  final EyeState eyeState;

  /// 分心分級（依頭部姿態近似）。
  final AttentionState attentionState;

  /// 目前的閉眼程度，0（全開）～ 1（全閉）。
  final double eyeClosure;

  /// 目前這一段連續閉眼已持續幾秒；眼睛張開時為 0。
  final double closureSeconds;

  /// 目前這一段連續偏離前方已持續幾秒；面向前方時為 0。
  final double awaySeconds;

  /// PERCLOS 近似值（0～1），滾動視窗內閉合程度超過門檻的時間佔比。
  final double perclos;

  /// PERCLOS 的滾動視窗是否已蓄滿；未滿時該數值僅供參考。
  final bool perclosWindowFilled;

  final double yawDegrees;
  final double pitchDegrees;
  final double rollDegrees;

  /// 是否處於需要警示的狀態。
  bool get isAlerting =>
      eyeState == EyeState.microsleep ||
      eyeState == EyeState.sleep ||
      eyeState == EyeState.unresponsive ||
      attentionState == AttentionState.longDistraction;
}

/// 逐幀餵入 blendshape 與頭部姿態，產生 [DriverState]。
///
/// 用法：
/// ```dart
/// final tracker = DriverStateTracker();
/// // 每一幀：
/// final state = tracker.update(
///   eyeClosure: math.max(bs[FaceBlendshape.eyeBlinkLeft],
///                        bs[FaceBlendshape.eyeBlinkRight]),
///   yawDegrees: pose.yawDegrees,
///   pitchDegrees: pose.pitchDegrees,
///   rollDegrees: pose.rollDegrees,
/// );
/// ```
class DriverStateTracker {
  DriverStateTracker({
    this.closedThreshold = 0.50,
    this.perclosThreshold = 0.80,
    this.perclosWindow = const Duration(seconds: 60),
    this.yawAwayDegrees = 30.0,
    this.pitchDownDegrees = -20.0,
  });

  /// 超過此值視為「閉眼」。範例原本用 0.45，這裡略保守。
  final double closedThreshold;

  /// PERCLOS 用的閉合門檻（學術定義是眼瞼閉合 80%）。
  final double perclosThreshold;

  /// PERCLOS 的滾動視窗長度。學術定義為 1 分鐘。
  final Duration perclosWindow;

  /// |yaw| 超過此角度視為偏離前方。
  final double yawAwayDegrees;

  /// pitch 低於此角度視為低頭（負值代表往下看）。
  final double pitchDownDegrees;

  DateTime? _closureStart;
  DateTime? _awayStart;

  /// PERCLOS 視窗：(時間, 是否閉合)。
  final Queue<_Sample> _window = Queue<_Sample>();

  /// 餵入一幀。[now] 可注入以便測試。
  DriverState update({
    required double eyeClosure,
    required double yawDegrees,
    required double pitchDegrees,
    required double rollDegrees,
    DateTime? now,
  }) {
    final DateTime t = now ?? DateTime.now();

    // ---- 閉眼時長 ----
    final bool closed = eyeClosure > closedThreshold;
    if (closed) {
      _closureStart ??= t;
    } else {
      _closureStart = null;
    }
    final double closureSeconds = _closureStart == null
        ? 0.0
        : t.difference(_closureStart!).inMilliseconds / 1000.0;

    // ---- PERCLOS 滾動視窗 ----
    _window.addLast(_Sample(t, eyeClosure > perclosThreshold));
    final DateTime cutoff = t.subtract(perclosWindow);
    while (_window.isNotEmpty && _window.first.time.isBefore(cutoff)) {
      _window.removeFirst();
    }
    final int closedCount = _window.where((s) => s.closed).length;
    final double perclos =
        _window.isEmpty ? 0.0 : closedCount / _window.length;
    final bool windowFilled = _window.isNotEmpty &&
        t.difference(_window.first.time) >= perclosWindow;

    // ---- 頭部姿態分心（近似）----
    final bool away =
        yawDegrees.abs() > yawAwayDegrees || pitchDegrees < pitchDownDegrees;
    if (away) {
      _awayStart ??= t;
    } else {
      _awayStart = null;
    }
    final double awaySeconds = _awayStart == null
        ? 0.0
        : t.difference(_awayStart!).inMilliseconds / 1000.0;

    return DriverState(
      eyeState: _classifyEye(closed, closureSeconds),
      attentionState: _classifyAttention(away, awaySeconds),
      eyeClosure: eyeClosure,
      closureSeconds: closureSeconds,
      awaySeconds: awaySeconds,
      perclos: perclos,
      perclosWindowFilled: windowFilled,
      yawDegrees: yawDegrees,
      pitchDegrees: pitchDegrees,
      rollDegrees: rollDegrees,
    );
  }

  /// 臉部消失時呼叫，避免把「偵測不到」誤算成「閉眼」。
  ///
  /// 🔴 這一點很重要：Euro NCAP 有一條獨立要求是「系統失效時必須在 10 秒內
  /// 告知駕駛」。把「看不到臉」和「眼睛閉著」混為一談，正是 fail-silent。
  void onFaceLost() {
    _closureStart = null;
    _awayStart = null;
  }

  void reset() {
    _closureStart = null;
    _awayStart = null;
    _window.clear();
  }

  EyeState _classifyEye(bool closed, double seconds) {
    if (!closed) return EyeState.open;
    if (seconds >= 6.0) return EyeState.unresponsive;
    if (seconds >= 3.0) return EyeState.sleep;
    if (seconds >= 1.0) return EyeState.microsleep;
    if (seconds >= 0.5) return EyeState.longBlink;
    return EyeState.blink;
  }

  AttentionState _classifyAttention(bool away, double seconds) {
    if (!away) return AttentionState.forward;
    if (seconds >= 3.0) return AttentionState.longDistraction;
    return AttentionState.glancingAway;
  }
}

class _Sample {
  const _Sample(this.time, this.closed);
  final DateTime time;
  final bool closed;
}

/// 給 UI 用的中文標籤與嚴重度。
extension EyeStateDisplay on EyeState {
  String get label => switch (this) {
        EyeState.open => '睜眼',
        EyeState.blink => '眨眼',
        EyeState.longBlink => '長眨眼',
        EyeState.microsleep => '微睡 MICROSLEEP',
        EyeState.sleep => '睡著 SLEEP',
        EyeState.unresponsive => '無反應 UNRESPONSIVE',
      };

  /// 0 = 正常，1 = 注意，2 = 警示。
  int get severity => switch (this) {
        EyeState.open || EyeState.blink => 0,
        EyeState.longBlink => 1,
        EyeState.microsleep || EyeState.sleep || EyeState.unresponsive => 2,
      };
}

extension AttentionStateDisplay on AttentionState {
  String get label => switch (this) {
        AttentionState.forward => '面向前方',
        AttentionState.glancingAway => '視線偏離',
        AttentionState.longDistraction => '長時間分心 DISTRACTED',
      };

  int get severity => switch (this) {
        AttentionState.forward => 0,
        AttentionState.glancingAway => 1,
        AttentionState.longDistraction => 2,
      };
}
