import 'package:flutter/foundation.dart';

import 'repair_task.dart';

/// Demonstration profiles, not specifications for any actual vehicle brand.
class CabinProfile {
  const CabinProfile._(this.id, this.label, this.supported, this.readable);

  static const a = CabinProfile._(
    'fictional-cabin-a',
    '模擬座艙 A',
    {CabinSetting.rearFan, CabinSetting.mediaVolume, CabinSetting.navVolume},
    {CabinSetting.rearFan, CabinSetting.mediaVolume, CabinSetting.navVolume},
  );
  static const b = CabinProfile._(
    'fictional-cabin-b',
    '模擬座艙 B',
    {CabinSetting.mediaVolume, CabinSetting.navVolume},
    {CabinSetting.mediaVolume, CabinSetting.navVolume},
  );

  final String id;
  final String label;
  final Set<CabinSetting> supported;
  final Set<CabinSetting> readable;
  int get revision => 1;

  Map<String, dynamic> toJson() => {
    'id': id,
    'revision': revision,
    'label': label,
    'fictional': true,
    'simulated': true,
    'supported': [for (final setting in supported) setting.name],
    'readable': [for (final setting in readable) setting.name],
    'scales': {
      for (final setting in supported)
        setting.name: {
          'min': 0,
          'max': setting == CabinSetting.rearFan ? 7 : 10,
        },
    },
  };
}

enum CabinAttentionPhase { clear, blocked, resumeRequired }

enum CabinDrivingMode { manual, assisted, handoverRequested, unknown }

class CabinContextIdentity {
  const CabinContextIdentity({
    required this.cabinSessionId,
    required this.profileId,
    required this.profileRevision,
    required this.attentionEpoch,
  });

  final String cabinSessionId;
  final String profileId;
  final int profileRevision;
  final int attentionEpoch;

  Map<String, dynamic> toJson() => {
    'cabin_session_id': cabinSessionId,
    'profile_id': profileId,
    'profile_revision': profileRevision,
    'attention_epoch': attentionEpoch,
  };

  static CabinContextIdentity? fromJson(Map<dynamic, dynamic> json) {
    final session = json['cabin_session_id'];
    final profile = json['profile_id'];
    final revision = json['profile_revision'];
    final epoch = json['attention_epoch'];
    if (session is! String ||
        session.isEmpty ||
        session.length > 120 ||
        profile is! String ||
        profile.isEmpty ||
        profile.length > 80 ||
        revision is! int ||
        revision < 1 ||
        epoch is! int ||
        epoch < 1) {
      return null;
    }
    return CabinContextIdentity(
      cabinSessionId: session,
      profileId: profile,
      profileRevision: revision,
      attentionEpoch: epoch,
    );
  }
}

/// Only a trusted host adapter constructs frames. sampledAt must be captured
/// from this policy's monotonicNow when a NEW source sample is obtained.
/// It is not an external device's wall-clock timestamp.
class CabinAttentionFrame {
  const CabinAttentionFrame({
    required this.sourceId,
    required this.sourceSession,
    required this.sequence,
    required this.episodeId,
    required this.sampledAt,
    this.mode = CabinDrivingMode.manual,
    this.active = false,
    this.known = true,
    this.simulated = true,
    this.reason,
  });

  final String sourceId;
  final String sourceSession;
  final int sequence;
  final String episodeId;
  final Duration sampledAt;
  final CabinDrivingMode mode;
  final bool active;
  final bool known;
  final bool simulated;

  /// 只有駕駛監測使用：'distracted'（視線偏離）或 'drowsy'（閉眼／疲勞）。
  final String? reason;
}

class _AttentionSource {
  _AttentionSource(this.session);
  final String session;
  int sequence = 0;
  String? episodeId;
  Duration? sampledAt;
  bool known = false;
  bool active = false;
  CabinDrivingMode mode = CabinDrivingMode.unknown;
  String? reason;
  final Set<String> retiredEpisodes = {};
}

/// Fixed local rules for the C demo. It does not decide whether a road is safe,
/// and it never executes or cancels a vehicle command.
class CabinPolicy extends ChangeNotifier {
  CabinPolicy(
    this.controller, {
    CabinProfile profile = CabinProfile.a,
    Duration Function()? monotonicNow,
    this.sourceTtl = const Duration(seconds: 3),
  }) : _profile = profile {
    if (sourceTtl <= Duration.zero) {
      throw ArgumentError.value(sourceTtl, 'sourceTtl');
    }
    final watch = Stopwatch()..start();
    _now = monotonicNow ?? (() => watch.elapsed);
    _lastClock = _now();
    _clockInvalid = _lastClock < Duration.zero;
    _sessionId = _newSession();
    controller.addListener(_taskChanged);
    _recompute(notify: false);
  }

  static const drivingSource = 'driving-context';
  static const safetySource = 'cockpit-safety';
  static const _requiredSources = {drivingSource, safetySource};

  /// 駕駛監測（前鏡頭＋臉部特徵點）是唯一的真實感知來源，屬於選配：
  /// 沒有註冊、過期或偵測不到臉時不鎖住系統（失效時照原本流程，畫面另外標示），
  /// 只有新鮮且確定「偏離／閉眼」時才暫停非緊急確認。
  static const driverMonitorSource = 'driver-monitor';
  static const _optionalSources = {driverMonitorSource};
  static int _sessionNumber = 0;
  static String _newSession() =>
      'cabin_${DateTime.now().microsecondsSinceEpoch}_${++_sessionNumber}';

  final RepairController controller;
  final Duration sourceTtl;
  late final Duration Function() _now;
  late Duration _lastClock;
  late String _sessionId;
  CabinProfile _profile;
  final Map<String, _AttentionSource> _sources = {};
  final Map<String, Set<String>> _retiredSourceSessions = {};
  List<String> _blockers = [];
  CabinDrivingMode _mode = CabinDrivingMode.unknown;
  CabinAttentionPhase _phase = CabinAttentionPhase.blocked;
  bool _resumeRequired = false;
  bool _clockInvalid = false;
  bool _disposed = false;
  int _attentionEpoch = 1;
  String _fingerprint = '';
  String _taskFingerprint = '';

  CabinProfile get profile => _profile;
  String get sessionId => _sessionId;
  int get attentionEpoch => _attentionEpoch;
  Duration get monotonicNow => _now();
  CabinAttentionPhase get attentionPhase => _phase;
  CabinDrivingMode get mode => _mode;
  bool get blocked => _blockers.isNotEmpty;
  bool get resumeRequired => _resumeRequired && !blocked;
  List<String> get blockers => List.unmodifiable(_blockers);

  Map<CabinSetting, String> get unsupported => Map.unmodifiable({
    for (final setting in controller.snapshot.pending.keys)
      if (!_profile.supported.contains(setting))
        setting: '本模擬座艙未提供${_settingLabel(setting)}控制介面',
  });

  bool get capabilityReady => unsupported.isEmpty;
  bool get executionReady => !_disposed && !blocked && capabilityReady;
  bool get canGrant => !_disposed && !blocked;

  CabinContextIdentity get identity => CabinContextIdentity(
    cabinSessionId: _sessionId,
    profileId: _profile.id,
    profileRevision: _profile.revision,
    attentionEpoch: _attentionEpoch,
  );

  /// Execution identity is deliberately independent of attention epochs: an
  /// alert after dispatch must not invalidate the eventual command ACK.
  Map<String, dynamic> get executionIdentity => {
    'cabin_session_id': _sessionId,
    'profile_id': _profile.id,
    'profile_revision': _profile.revision,
  };

  static String _settingLabel(CabinSetting setting) => switch (setting) {
    CabinSetting.rearFan => '後座風量',
    CabinSetting.mediaVolume => '音樂音量',
    CabinSetting.navVolume => '導航音量',
  };

  bool get _hasActiveTask => !const {
    RepairPhase.idle,
    RepairPhase.completed,
    RepairPhase.cancelled,
  }.contains(controller.snapshot.phase);

  /// Registration is privileged local configuration, never a socket command.
  /// Reusing a retired source session is refused, even with a new sequence.
  bool registerSource(String sourceId, String sourceSession) {
    if (_disposed ||
        !(_requiredSources.contains(sourceId) ||
            _optionalSources.contains(sourceId)) ||
        sourceSession.isEmpty ||
        sourceSession.length > 120 ||
        (_retiredSourceSessions[sourceId]?.contains(sourceSession) ?? false)) {
      return false;
    }
    final previous = _sources[sourceId];
    if (previous?.session == sourceSession) return true;
    if (previous != null) {
      _retiredSourceSessions
          .putIfAbsent(sourceId, () => {})
          .add(previous.session);
    }
    _sources[sourceId] = _AttentionSource(sourceSession);
    refresh();
    return true;
  }

  bool observe(CabinAttentionFrame frame) {
    if (_disposed) return false;
    final now = _readClock();
    final source = _sources[frame.sourceId];
    if (_clockInvalid ||
        source == null ||
        source.session != frame.sourceSession ||
        frame.sequence <= source.sequence ||
        frame.sequence < 1 ||
        frame.episodeId.isEmpty ||
        frame.episodeId.length > 120 ||
        // 車輛訊號仍是模擬；只有駕駛監測可以是真實鏡頭訊號。
        (!frame.simulated && frame.sourceId != driverMonitorSource) ||
        (frame.sourceId == driverMonitorSource &&
            frame.active &&
            !const {'distracted', 'drowsy'}.contains(frame.reason)) ||
        frame.sampledAt < Duration.zero ||
        frame.sampledAt > now ||
        now - frame.sampledAt >= sourceTtl ||
        (source.sampledAt != null && frame.sampledAt < source.sampledAt!)) {
      _recompute();
      return false;
    }
    if (frame.known &&
        (source.retiredEpisodes.contains(frame.episodeId) &&
            (frame.active || source.episodeId != frame.episodeId))) {
      _recompute();
      return false;
    }
    // A late 'end' cannot clear a newer active episode, even if it is packaged
    // in a new sequence. An unknown signal also cannot silently clear it.
    if (frame.known &&
        !frame.active &&
        source.active &&
        source.episodeId != frame.episodeId) {
      _recompute();
      return false;
    }
    if (frame.sourceId == drivingSource &&
        frame.known &&
        ((frame.mode == CabinDrivingMode.handoverRequested) != frame.active)) {
      _recompute();
      return false;
    }
    source.sequence = frame.sequence;
    source.sampledAt = frame.sampledAt;
    source.known = frame.known && frame.mode != CabinDrivingMode.unknown;
    if (source.known) {
      if (source.episodeId != null && source.episodeId != frame.episodeId) {
        source.retiredEpisodes.add(source.episodeId!);
      }
      if (source.active && !frame.active) {
        source.retiredEpisodes.add(frame.episodeId);
      }
      source.active = frame.active;
      source.episodeId = frame.episodeId;
      source.mode = frame.mode;
      source.reason = frame.active ? frame.reason : null;
    }
    _recompute();
    return true;
  }

  Duration _readClock() {
    final now = _now();
    _clockInvalid = now < Duration.zero || now < _lastClock;
    if (_clockInvalid) {
      // Catching up to the old clock value must not make old samples appear
      // fresh again. Each source needs a new, valid baseline after rollback.
      for (final source in _sources.values) {
        source.known = false;
      }
    }
    if (!_clockInvalid) _lastClock = now;
    return now;
  }

  /// Invoked synchronously at every command/merge boundary, as well as by the
  /// collaboration watchdog. It does not rely on the next timer callback.
  void refresh() {
    if (_disposed) return;
    _readClock();
    _recompute();
  }

  void _taskChanged() {
    if (_disposed) return;
    _readClock();
    _recompute();
  }

  void _recompute({bool notify = true}) {
    final now = _lastClock;
    final next = <String>[];
    if (_clockInvalid) next.add('clock_unconfirmed');
    for (final id in _requiredSources) {
      final source = _sources[id];
      if (source == null || source.sampledAt == null) {
        next.add('${id}_unknown');
      } else {
        final age = now - source.sampledAt!;
        if (age < Duration.zero || age >= sourceTtl) {
          next.add('${id}_stale');
        } else if (!source.known) {
          next.add('${id}_unknown');
        }
        if (source.active) {
          next.add(
            id == drivingSource ? 'handover_requested' : 'priority_alert',
          );
        }
      }
    }
    final monitor = _sources[driverMonitorSource];
    if (_driverMonitorFresh(monitor, now) && monitor!.known && monitor.active) {
      next.add(
        monitor.reason == 'drowsy' ? 'driver_drowsy' : 'driver_distracted',
      );
    }
    next.sort();
    final driving = _sources[drivingSource];
    _mode =
        driving != null &&
            driving.known &&
            driving.sampledAt != null &&
            now - driving.sampledAt! >= Duration.zero &&
            now - driving.sampledAt! < sourceTtl &&
            !_clockInvalid
        ? driving.mode
        : CabinDrivingMode.unknown;
    final wasBlocked = _blockers.isNotEmpty;
    _blockers = next;
    if (!_hasActiveTask) {
      _resumeRequired = false;
    } else if (wasBlocked && next.isEmpty) {
      _resumeRequired = true;
    }
    _phase = next.isNotEmpty
        ? CabinAttentionPhase.blocked
        : _resumeRequired
        ? CabinAttentionPhase.resumeRequired
        : CabinAttentionPhase.clear;
    final fingerprint = '${_phase.name}|${_mode.name}|${next.join(',')}';
    final task = controller.snapshot;
    final taskFingerprint =
        '${task.taskId}|${task.revision}|${task.phase.name}|${unsupported.keys.map((e) => e.name).join(',')}';
    final attentionChanged = _fingerprint != fingerprint;
    final taskChanged = _taskFingerprint != taskFingerprint;
    if (_fingerprint.isNotEmpty && attentionChanged) ++_attentionEpoch;
    _fingerprint = fingerprint;
    _taskFingerprint = taskFingerprint;
    if (notify && (attentionChanged || taskChanged)) notifyListeners();
  }

  bool _driverMonitorFresh(_AttentionSource? source, Duration now) {
    final sampled = source?.sampledAt;
    if (source == null || sampled == null || _clockInvalid) return false;
    final age = now - sampled;
    return age >= Duration.zero && age < sourceTtl;
  }

  /// 畫面用：off（沒有駕駛端鏡頭）／stale（訊號中斷）／no_face（看不到臉）／live。
  Map<String, dynamic> get driverMonitorStatus {
    final source = _sources[driverMonitorSource];
    final fresh = _driverMonitorFresh(source, _lastClock);
    return {
      'state': source == null || source.sampledAt == null
          ? 'off'
          : !fresh
          ? 'stale'
          : !source.known
          ? 'no_face'
          : 'live',
      'active': fresh && (source?.known ?? false) && (source?.active ?? false),
      'reason': fresh && (source?.active ?? false) ? source?.reason : null,
      'simulated': false,
    };
  }

  bool matchesSession(String? session) =>
      !_disposed && session != null && session == _sessionId;

  bool matches(CabinContextIdentity? context) {
    refresh();
    return context != null &&
        matchesSession(context.cabinSessionId) &&
        context.profileId == _profile.id &&
        context.profileRevision == _profile.revision &&
        context.attentionEpoch == _attentionEpoch;
  }

  bool canConfirm({required bool resume}) {
    refresh();
    return executionReady && resume == _resumeRequired;
  }

  /// Must be called only after controller.confirm has synchronously admitted
  /// the command. This never runs an actuator or changes the task revision.
  void markConfirmAdmitted() {
    if (_disposed || !_resumeRequired) return;
    _resumeRequired = false;
    _recompute();
  }

  bool startSession(CabinProfile profile, {required bool parked}) {
    if (_disposed ||
        !parked ||
        !const {
          RepairPhase.idle,
          RepairPhase.completed,
          RepairPhase.cancelled,
        }.contains(controller.snapshot.phase) ||
        !controller.resetForSession()) {
      return false;
    }
    _profile = profile;
    _sessionId = _newSession();
    ++_attentionEpoch;
    for (final entry in _sources.entries) {
      _retiredSourceSessions
          .putIfAbsent(entry.key, () => {})
          .add(entry.value.session);
    }
    _sources.clear();
    _resumeRequired = false;
    _recompute();
    // Even A -> A must notify a new session, although blockers may be equal.
    notifyListeners();
    return true;
  }

  Map<String, dynamic> toJson() {
    final task = controller.snapshot;
    final phaseReady =
        task.phase == RepairPhase.awaitingConfirmation &&
        task.clarification == null &&
        task.pending.isNotEmpty;
    return {
      ...identity.toJson(),
      'profile': _profile.toJson(),
      'attention': {
        'epoch': _attentionEpoch,
        'phase': _phase == CabinAttentionPhase.resumeRequired
            ? 'resume_required'
            : _phase.name,
        'mode': _mode.name,
        'blockers': List<String>.of(_blockers),
        // 車輛模式與警示仍是模擬；駕駛監測另列在 driver_monitor，是真實鏡頭訊號。
        'simulated': true,
        'driver_monitor': driverMonitorStatus,
        'source_ttl_ms': sourceTtl.inMilliseconds,
        'sources': {
          for (final id in _requiredSources)
            id: {
              'source_session': _sources[id]?.session,
              'sequence': _sources[id]?.sequence,
              'episode_id': _sources[id]?.episodeId,
              'known': _sources[id]?.known ?? false,
              'active': _sources[id]?.active ?? false,
              'age_ms': _sources[id]?.sampledAt == null
                  ? null
                  : (_lastClock - _sources[id]!.sampledAt!).inMilliseconds,
            },
        },
      },
      'capability': {
        'task_id': task.taskId,
        'revision': task.revision,
        'ready': capabilityReady,
        'unsupported': {
          for (final entry in unsupported.entries) entry.key.name: entry.value,
        },
      },
      'can_grant': canGrant,
      'can_confirm': phaseReady && executionReady && !resumeRequired,
      'can_resume_confirm': phaseReady && executionReady && resumeRequired,
      'requires_resume': resumeRequired,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_taskChanged);
    super.dispose();
  }
}
