import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'repair_task.dart';
import 'cabin_policy.dart';

/// One passenger drafts/edits; one paired driver grants and confirms.
/// This is deliberately not ownership handoff or shared-setting arbitration.
class RepairCollaboration extends ChangeNotifier {
  RepairCollaboration(
    this.controller, {
    DateTime Function()? clock,
    this.authorizationDuration = const Duration(seconds: 120),
    this.heartbeatTimeout = const Duration(seconds: 6),
    // Explicit unit-test override; production UI must leave this unset.
    bool? demoFaultsForTesting,
    this.policy,
  }) : _clock = clock ?? DateTime.now,
       _demoFaultAllowed =
           demoFaultsForTesting ??
           const bool.fromEnvironment('REPAIR_DESKTOP_DEMO') {
    _lastObservedClock = _clock();
    _pairingCode = _newCode();
    _previousGuard = controller.confirmationGuard;
    _guard = (id, revision) =>
        _confirmingDriver &&
        driverOnline &&
        (policy == null ||
            (policy!.executionReady &&
                (!policy!.resumeRequired || _admittingResume))) &&
        (_previousGuard?.call(id, revision) ?? true);
    controller.confirmationGuard = _guard;
    controller.addListener(_taskChanged);
    policy?.addListener(_policyChanged);
    _watch = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => checkTimeouts(),
    );
  }

  final RepairController controller;
  final CabinPolicy? policy;
  final DateTime Function() _clock;
  final Duration authorizationDuration;
  final Duration heartbeatTimeout;
  final bool _demoFaultAllowed;
  Map<String, dynamic>? _demoFault;
  Map<String, dynamic>? _completedDemoFault;
  late String _pairingCode;
  late final bool Function(String, int) _guard;
  bool Function(String, int)? _previousGuard;
  Object? _driver;
  DateTime? _lastHeartbeat;
  late DateTime _lastObservedClock;
  bool _clockReliable = true;
  String? _authorizedTaskId;
  DateTime? _authorizationExpires;
  Timer? _watch;
  bool _confirmingDriver = false;
  bool _admittingResume = false;
  bool _disposed = false;
  String? error;
  void Function(Object driver)? onDriverExpired;

  String _newCode() =>
      Random.secure().nextInt(1000000).toString().padLeft(6, '0');
  String get pairingCode => _pairingCode;
  bool get driverOnline {
    final now = _clock();
    return _clockReliable &&
        !now.isBefore(_lastObservedClock) &&
        _driver != null &&
        _lastHeartbeat != null &&
        !now.isBefore(_lastHeartbeat!) &&
        now.difference(_lastHeartbeat!) < heartbeatTimeout;
  }

  bool isDriver(Object peer) => identical(peer, _driver) && driverOnline;
  bool get canRevise =>
      !_disposed &&
      driverOnline &&
      _authorizedTaskId != null &&
      _authorizedTaskId == controller.snapshot.taskId &&
      _authorizationExpires != null &&
      _clock().isBefore(_authorizationExpires!) &&
      !const {
        RepairPhase.idle,
        RepairPhase.completed,
        RepairPhase.cancelled,
        RepairPhase.executing,
        RepairPhase.indeterminate,
      }.contains(controller.snapshot.phase);

  Map<String, dynamic> toJson() => {
    'paired': _driver != null,
    'driver_online': driverOnline,
    'passenger_authorized': canRevise,
    'authorization_task_id': _authorizedTaskId,
    'authorization_expires_at': _authorizationExpires?.millisecondsSinceEpoch,
    if (_demoFault != null &&
        _demoFault!['task_id'] == controller.snapshot.taskId)
      'demo_fault': Map<String, dynamic>.of(_demoFault!),
    if (_completedDemoFault != null &&
        _completedDemoFault!['task_id'] == controller.snapshot.taskId)
      'demo_fault_source': Map<String, dynamic>.of(_completedDemoFault!),
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _reject(String message) {
    error = message;
    _notify();
    return false;
  }

  void _release({bool invalidate = true}) {
    final hadLease = _authorizedTaskId != null;
    _authorizedTaskId = null;
    _authorizationExpires = null;
    if (hadLease && invalidate) controller.invalidatePendingParse();
  }

  void _taskChanged() {
    final task = controller.snapshot;
    if (_demoFault != null) {
      if (_demoFault!['task_id'] != task.taskId ||
          task.phase == RepairPhase.cancelled) {
        _demoFault = null;
        _completedDemoFault = null;
      } else if (task.phase == RepairPhase.completed) {
        _completedDemoFault = {..._demoFault!, 'label': '這次結果包含展示安排的誤解來源'};
        _demoFault = null;
      }
    }
    if (_completedDemoFault != null &&
        (_completedDemoFault!['task_id'] != task.taskId ||
            task.phase == RepairPhase.cancelled)) {
      _completedDemoFault = null;
    }
    if (_authorizedTaskId != null &&
        (task.taskId != _authorizedTaskId ||
            task.phase == RepairPhase.cancelled ||
            task.phase == RepairPhase.completed)) {
      _release(invalidate: false);
    }
    _notify();
  }

  void _policyChanged() => _notify();

  /// Called by the watchdog and synchronously before every command. Tests can
  /// advance an injected clock without sleeps or touching a running demo port.
  void checkTimeouts() {
    if (_disposed) return;
    policy?.refresh();
    final now = _clock();
    final wasClockReliable = _clockReliable;
    _clockReliable = !now.isBefore(_lastObservedClock);
    if (!_clockReliable) {
      if (wasClockReliable || _driver != null || _authorizedTaskId != null) {
        final expired = _driver;
        _driver = null;
        _lastHeartbeat = null;
        _pairingCode = _newCode();
        _release();
        error = '裝置時間發生倒退，修正授權已收回；時間確認後請重新配對。';
        if (expired != null) onDriverExpired?.call(expired);
        _notify();
      }
      return;
    }
    _lastObservedClock = now;
    if (_driver != null && !driverOnline) {
      final expired = _driver!;
      _driver = null;
      _lastHeartbeat = null;
      _pairingCode = _newCode();
      _release();
      error = '駕駛連線逾時，修正授權已收回；請重新配對。';
      onDriverExpired?.call(expired);
      _notify();
    } else if (_authorizationExpires != null &&
        !_clock().isBefore(_authorizationExpires!)) {
      _release();
      error = '修正授權已到期，先前需求保留。';
      _notify();
    }
  }

  bool pairDriver(Object peer, String code, {String? sessionId}) {
    checkTimeouts();
    if (_disposed) return false;
    if (!_clockReliable) return _reject('裝置時間尚未確認，請稍後重新配對。');
    if (policy != null && !policy!.matchesSession(sessionId)) {
      return _reject('座艙場景已更新，請重新查看配對碼。');
    }
    if (_driver != null && !identical(_driver, peer)) {
      return _reject('已有駕駛端配對。');
    }
    if (code != _pairingCode) return _reject('配對碼不正確。');
    _driver = peer;
    _lastHeartbeat = _clock();
    error = null;
    _notify();
    return true;
  }

  bool heartbeat(Object peer, {String? sessionId}) {
    checkTimeouts();
    if (policy != null && !policy!.matchesSession(sessionId)) {
      return _reject('座艙場景已更新，請重新配對。');
    }
    if (!isDriver(peer)) return _reject('請先配對駕駛端。');
    _lastHeartbeat = _clock();
    return true;
  }

  bool _current(
    Object peer,
    String taskId,
    int revision, {
    CabinContextIdentity? context,
  }) {
    checkTimeouts();
    if (_disposed) return false;
    if (policy != null && !policy!.matches(context)) {
      return _reject('座艙或注意力狀態已更新，請查看最新摘要。');
    }
    if (!isDriver(peer)) return _reject('此連線沒有駕駛操作權限。');
    final task = controller.snapshot;
    if (task.taskId != taskId || task.revision != revision) {
      return _reject('需求版本已更新，請查看最新摘要。');
    }
    return true;
  }

  bool grant(
    Object peer,
    String taskId,
    int revision, {
    CabinContextIdentity? context,
  }) {
    if (!_current(peer, taskId, revision, context: context)) return false;
    if (policy != null && !policy!.canGrant) {
      return _reject('優先事件或模式訊號尚未解除，暫停新的修正授權。');
    }
    if (!const {
      RepairPhase.awaitingConfirmation,
      RepairPhase.awaitingClarification,
      RepairPhase.failed,
    }.contains(controller.snapshot.phase)) {
      return _reject('目前不能授權修正。');
    }
    _authorizedTaskId = taskId;
    _authorizationExpires = _clock().add(authorizationDuration);
    error = null;
    _notify();
    return true;
  }

  bool revoke(
    Object peer,
    String taskId,
    int revision, {
    CabinContextIdentity? context,
  }) {
    if (!_current(peer, taskId, revision, context: context)) return false;
    _release();
    error = null;
    _notify();
    return true;
  }

  bool confirm(
    Object peer,
    String taskId,
    int revision, {
    CabinContextIdentity? context,
    bool resume = false,
  }) {
    if (!_current(peer, taskId, revision, context: context)) return false;
    if (policy != null && !policy!.canConfirm(resume: resume)) {
      return _reject(
        policy!.blocked
            ? '確認暫停；需求已保留，等待優先事件與模式訊號確認。'
            : !policy!.capabilityReady
            ? '本座艙有不支援項目，請明確修正後再確認。'
            : '需求已保留，請以最新摘要明確繼續確認。',
      );
    }
    final task = controller.snapshot;
    if (task.phase != RepairPhase.awaitingConfirmation ||
        task.pending.isEmpty ||
        task.clarification != null ||
        !(_previousGuard?.call(taskId, revision) ?? true)) {
      return _reject('需求尚未準備好，不能確認。');
    }
    error = null;
    _confirmingDriver = true;
    _admittingResume = resume;
    try {
      // Admission is synchronous; completion still comes from the real ACK
      // path. Neither a slow actuator nor a parser blocks safety broadcasts.
      unawaited(controller.confirm(taskId, revision));
      if (!const {
        RepairPhase.executing,
        RepairPhase.indeterminate,
      }.contains(controller.snapshot.phase)) {
        return _reject('需求尚未準備好，未送出控制。');
      }
      policy?.markConfirmAdmitted();
    } finally {
      _confirmingDriver = false;
      _admittingResume = false;
    }
    return true;
  }

  bool cancelByDriver(
    Object peer,
    String taskId,
    int revision, {
    CabinContextIdentity? context,
  }) {
    if (!_current(peer, taskId, revision, context: context)) return false;
    return cancel();
  }

  /// Privileged host demonstration setting. No socket command exposes this.
  bool startCabinSession(CabinProfile profile, {required bool parked}) {
    checkTimeouts();
    if (_disposed ||
        policy == null ||
        !policy!.startSession(profile, parked: parked)) {
      return _reject('請先停車並結束未完成需求；執行中或結果未知不能換場景。');
    }
    _driver = null;
    _lastHeartbeat = null;
    _pairingCode = _newCode();
    _release(invalidate: false);
    _demoFault = null;
    _completedDemoFault = null;
    error = null;
    _notify();
    return true;
  }

  void disconnectDriver(Object peer) {
    if (!identical(_driver, peer)) return;
    _driver = null;
    _lastHeartbeat = null;
    _pairingCode = _newCode();
    _release();
    _notify();
  }

  Future<bool> newTask(String text) {
    if (_disposed) return Future.value(false);
    _demoFault = null;
    _completedDemoFault = null;
    checkTimeouts();
    _release();
    error = null;
    _notify();
    return controller.newTask(text);
  }

  Future<bool> revise(String text) {
    checkTimeouts();
    if (!canRevise) {
      _reject('請先取得駕駛對這次需求的修正授權。');
      return Future.value(false);
    }
    error = null;
    // Recheck at the actual merge boundary too: an answer can arrive between
    // the lease deadline and the next watchdog tick.
    return controller.revise(text, acceptanceGuard: () => canRevise);
  }

  bool directPatch(CabinSetting setting, RequestedChange change) {
    checkTimeouts();
    if (!canRevise) return _reject('請先取得駕駛對這次需求的修正授權。');
    error = null;
    final task = controller.snapshot;
    // A setting button cannot establish which unresolved slot was answered.
    // Preserve the question until an explicit text answer resolves it.
    return controller.applyPatch(
      IntentPatch(
        changes: {setting: change},
        clarification: task.clarification,
        unresolvedTextOverride: task.unresolvedText,
      ),
    );
  }

  /// Intentionally arranged showcase error, never a claim about model quality.
  /// It changes only a pending proposal, grants no permission, and never runs
  /// the actuator. Native production builds cannot enable this by default.
  bool injectDemoMisunderstanding() {
    if (_disposed || !_demoFaultAllowed) return false;
    final task = controller.snapshot;
    final original = task.pending[CabinSetting.navVolume];
    if (task.phase != RepairPhase.awaitingConfirmation ||
        task.taskId == null ||
        original == null ||
        original == RequestedChange.decrease) {
      return false;
    }
    _demoFault = {
      'label': '展示安排的誤解，尚未執行',
      'setting': 'navVolume',
      'before': original.name,
      'injected': 'decrease',
      'source': 'manual_demo_injection',
      'task_id': task.taskId,
    };
    _completedDemoFault = null;
    final accepted = controller.applyPatch(
      IntentPatch(changes: {CabinSetting.navVolume: RequestedChange.decrease}),
    );
    if (!accepted) _demoFault = null;
    return accepted;
  }

  bool cancel() {
    if (_disposed) return false;
    error = null;
    final cancelled = controller.cancel();
    if (cancelled) {
      _release(invalidate: false);
      _notify();
    }
    return cancelled;
  }

  @override
  void dispose() {
    _disposed = true;
    _watch?.cancel();
    controller.removeListener(_taskChanged);
    policy?.removeListener(_policyChanged);
    _release();
    _driver = null;
    _lastHeartbeat = null;
    if (identical(controller.confirmationGuard, _guard)) {
      controller.confirmationGuard = _previousGuard;
    }
    super.dispose();
  }
}
