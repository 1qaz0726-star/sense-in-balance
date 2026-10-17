import 'cabin_policy.dart';

/// 駕駛端手機的前鏡頭監測 → C 注意力規則。只由主控端在收到「已配對駕駛」
/// 的 driver_monitor 指令時呼叫；取樣時間一律用主控自己的單調時鐘，不信任手機時間。
///
/// 對應（門檻在駕駛端，依 Euro NCAP v1.2）：
/// - attention == long_distraction（單次偏離 ≥3 秒）→ distracted
/// - eyes ∈ {microsleep, sleep, unresponsive}（閉眼 ≥1 秒）→ drowsy
/// - face == false → 不確定，不鎖住系統（畫面標示「偵測不到臉」）
class CabinDriverMonitorSource {
  CabinDriverMonitorSource(this.policy);
  final CabinPolicy policy;

  static const _attention = {'forward', 'glancing_away', 'long_distraction'};
  static const _eyes = {
    'open',
    'blink',
    'long_blink',
    'microsleep',
    'sleep',
    'unresponsive',
  };
  static const _drowsyEyes = {'microsleep', 'sleep', 'unresponsive'};

  String? _registeredFor;
  String _sourceSession = '';
  int _sequence = 0, _episode = 0, _lastClientSeq = -1;
  bool _active = false;
  String? _reason;

  String get _episodeId => '$_sourceSession-dms-$_episode';

  /// 回傳是否被接受；格式不對、序號倒退都拒收（不更新狀態）。
  bool sample(Object? monitor) {
    if (monitor is! Map ||
        monitor.length != 6 ||
        monitor['seq'] is! int ||
        monitor['face'] is! bool ||
        !_attention.contains(monitor['attention']) ||
        !_eyes.contains(monitor['eyes']) ||
        monitor['away_ms'] is! int ||
        monitor['closure_ms'] is! int) {
      return false;
    }
    final session = policy.sessionId;
    if (_registeredFor != session) {
      // 新的座艙工作階段：舊的監測來源一律作廢，重新註冊。
      _sourceSession = '$session-dms';
      if (!policy.registerSource(
        CabinPolicy.driverMonitorSource,
        _sourceSession,
      )) {
        return false;
      }
      _registeredFor = session;
      _sequence = 0;
      _lastClientSeq = -1;
      _active = false;
      _reason = null;
    }
    final seq = monitor['seq'] as int;
    if (seq <= _lastClientSeq) return false;
    _lastClientSeq = seq;

    final face = monitor['face'] as bool;
    final drowsy = face && _drowsyEyes.contains(monitor['eyes']);
    final distracted = face && monitor['attention'] == 'long_distraction';
    final active = drowsy || distracted;
    final reason = drowsy ? 'drowsy' : (distracted ? 'distracted' : null);
    // 新的一次偏離／閉眼（或原因改變）才開新事件；結束要沿用同一事件編號。
    if (active && (!_active || reason != _reason)) {
      if (_active) {
        policy.observe(_frame(active: false, known: true, reason: null));
      }
      ++_episode;
    }
    if (face) {
      _active = active;
      _reason = reason;
    }
    return policy.observe(
      _frame(
        active: face ? active : _active,
        known: face,
        reason: face ? reason : _reason,
      ),
    );
  }

  CabinAttentionFrame _frame({
    required bool active,
    required bool known,
    required String? reason,
  }) => CabinAttentionFrame(
    sourceId: CabinPolicy.driverMonitorSource,
    sourceSession: _sourceSession,
    sequence: ++_sequence,
    episodeId: _episodeId,
    sampledAt: policy.monotonicNow,
    known: known,
    active: active,
    reason: reason,
    simulated: false,
  );
}
