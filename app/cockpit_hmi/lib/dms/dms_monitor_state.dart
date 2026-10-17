// 駕駛監測（DMS）的共用狀態與「狀態 → 送出 JSON」對應。
//
// 本檔只依賴 Flutter 基本函式庫與 driver_state.dart（兩者都不碰 dart:ffi），
// 網頁版與原生版都能匯入。真正開鏡頭的實作在 driver_monitor.dart（僅原生），
// 網頁版改用 dms_monitor_stub.dart，DMS 一律關閉。
import 'package:flutter/foundation.dart';

import 'driver_state.dart';

/// 本機鏡頭／監測管線的狀態，只用來決定駕駛畫面上的小燈號。
enum DmsStatus {
  /// 這個平台不支援（網頁版、非 Android）。
  unsupported,

  /// 支援，但目前沒有啟用（尚未配對駕駛、或 App 在背景）。
  off,

  /// 正在開鏡頭、載入模型。
  starting,

  /// 偵測中。
  running,

  /// 使用者拒絕鏡頭權限。
  permissionDenied,

  /// 其他錯誤，細節在 [DriverMonitorState.error]。
  failed,
}

/// 駕駛監測目前的讀數。只含數值與列舉，不含任何影像。
class DriverMonitorState extends ChangeNotifier {
  DmsStatus _status = DmsStatus.unsupported;
  bool _face = false;
  AttentionState _attention = AttentionState.forward;
  EyeState _eyes = EyeState.open;
  int _awayMs = 0;
  int _closureMs = 0;
  double _fps = 0;
  String? _error;

  DmsStatus get status => _status;
  bool get face => _face;
  AttentionState get attention => _attention;
  EyeState get eyes => _eyes;
  int get awayMs => _awayMs;
  int get closureMs => _closureMs;
  double get fps => _fps;
  String? get error => _error;

  /// 是否正在送出有效讀數（鏡頭在跑）。
  bool get active => _status == DmsStatus.running;

  @protected
  void setStatus(DmsStatus value, {String? error}) {
    if (_status == value && _error == error) return;
    _status = value;
    _error = error;
    if (value != DmsStatus.running) {
      _clearReading();
      _fps = 0;
    }
    notifyListeners();
  }

  /// 一幀判讀結果。
  @protected
  void applyDriverState(DriverState state) {
    _face = true;
    _attention = state.attentionState;
    _eyes = state.eyeState;
    _awayMs = (state.awaySeconds * 1000).round();
    _closureMs = (state.closureSeconds * 1000).round();
    notifyListeners();
  }

  /// 這一幀看不到臉。
  @protected
  void applyNoFace() {
    _clearReading();
    notifyListeners();
  }

  @protected
  void applyFps(double value) {
    _fps = value;
    notifyListeners();
  }

  void _clearReading() {
    _face = false;
    _attention = AttentionState.forward;
    _eyes = EyeState.open;
    _awayMs = 0;
    _closureMs = 0;
  }

  /// 測試用：直接設定整組讀數。
  @visibleForTesting
  void debugSet({
    DmsStatus status = DmsStatus.running,
    bool face = true,
    AttentionState attention = AttentionState.forward,
    EyeState eyes = EyeState.open,
    int awayMs = 0,
    int closureMs = 0,
    double fps = 0,
    String? error,
  }) {
    _status = status;
    _face = face;
    _attention = attention;
    _eyes = eyes;
    _awayMs = awayMs;
    _closureMs = closureMs;
    _fps = fps;
    _error = error;
    notifyListeners();
  }
}

/// 送給主控端的 attention 字串。
String dmsAttentionWire(AttentionState value) => switch (value) {
  AttentionState.forward => 'forward',
  AttentionState.glancingAway => 'glancing_away',
  AttentionState.longDistraction => 'long_distraction',
};

/// 送給主控端的 eyes 字串。
String dmsEyesWire(EyeState value) => switch (value) {
  EyeState.open => 'open',
  EyeState.blink => 'blink',
  EyeState.longBlink => 'long_blink',
  EyeState.microsleep => 'microsleep',
  EyeState.sleep => 'sleep',
  EyeState.unresponsive => 'unresponsive',
};

/// `monitor` 物件：剛好 6 個欄位，主控端多一個或少一個都會丟掉整筆。
Map<String, Object> dmsMonitorJson(DriverMonitorState state, int seq) => {
  'seq': seq,
  'face': state.face,
  'attention': dmsAttentionWire(state.attention),
  'eyes': dmsEyesWire(state.eyes),
  'away_ms': state.awayMs,
  'closure_ms': state.closureMs,
};

/// 整筆指令：剛好 5 個欄位。不使用 pendingCommandId，主控端不回覆。
Map<String, Object> dmsCommandJson({
  required String commandId,
  required Object cabinSessionId,
  required DriverMonitorState state,
  required int seq,
}) => {
  'type': 'repair_command',
  'command_id': commandId,
  'action': 'driver_monitor',
  'cabin_session_id': cabinSessionId,
  'monitor': dmsMonitorJson(state, seq),
};

/// 駕駛畫面小燈號的文字。只描述本機鏡頭，看路狀態由主控端的注意力列顯示。
String dmsChipText(DriverMonitorState state) {
  switch (state.status) {
    case DmsStatus.permissionDenied:
      return '鏡頭未授權';
    case DmsStatus.unsupported:
    case DmsStatus.off:
      return '鏡頭未啟用';
    case DmsStatus.failed:
      return '鏡頭錯誤';
    case DmsStatus.starting:
      return '鏡頭啟動中';
    case DmsStatus.running:
      final parts = <String>['偵測中 ${state.fps.round()} fps'];
      if (state.awayMs > 0) {
        parts.add('偏離 ${(state.awayMs / 1000).toStringAsFixed(1)} 秒');
      }
      if (state.closureMs > 0) {
        parts.add('閉眼 ${(state.closureMs / 1000).toStringAsFixed(1)} 秒');
      }
      return parts.join(' · ');
  }
}
