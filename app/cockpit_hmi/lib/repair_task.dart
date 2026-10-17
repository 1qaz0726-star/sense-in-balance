// 「不用重講」核心：模型只提出修正，確認及執行由固定規則管理。
// 車控 adapter 目前只有 MockCabinActuator，所有結果均明示模擬。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

enum CabinSetting { rearFan, mediaVolume, navVolume }

enum RequestedChange { decrease, increase, keep, remove }

enum RepairPhase {
  idle,
  parsing,
  awaitingClarification,
  awaitingConfirmation,
  executing,
  completed,
  cancelled,
  failed,
  indeterminate,
}

class IntentPatch {
  IntentPatch({
    required Map<CabinSetting, RequestedChange> changes,
    this.clarification,
    this.unresolvedTextOverride,
    this.source = 'local',
  }) : changes = Map.unmodifiable(changes);

  final Map<CabinSetting, RequestedChange> changes;
  final String? clarification;

  /// Internal parser metadata for a new full request that replaces an older
  /// unresolved sentence. Never accepted as an extra model JSON field.
  final String? unresolvedTextOverride;

  /// 這次修正由誰提出：'local'（端側模型或規則）或 'cloud'（連網時的雲端解讀）。
  /// 只供畫面照實標示，不是模型 JSON 欄位，也不改變確認流程。
  final String source;

  /// 只接受完整 JSON；不抽取 code fence，不補括號，不猜未知欄位。
  factory IntentPatch.fromModelOutput(String raw) {
    if (raw.length > 16384) {
      throw const FormatException('模型輸出過長');
    }
    final decoded = jsonDecode(raw);
    _rejectDuplicateObjectKeys(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 2 ||
        !decoded.containsKey('changes') ||
        !decoded.containsKey('clarification')) {
      throw const FormatException('僅接受 changes 與 clarification 兩個欄位');
    }
    final rawChanges = decoded['changes'];
    final clarification = decoded['clarification'];
    if (rawChanges is! Map<String, dynamic>) {
      throw const FormatException('changes 必須是 JSON object');
    }
    if (clarification != null &&
        (clarification is! String ||
            clarification.trim().isEmpty ||
            clarification.length > 256)) {
      throw const FormatException('clarification 必須是 null 或非空短字串');
    }
    final changes = <CabinSetting, RequestedChange>{};
    for (final entry in rawChanges.entries) {
      final settings = CabinSetting.values.where((e) => e.name == entry.key);
      final values = RequestedChange.values.where((e) => e.name == entry.value);
      if (settings.isEmpty || values.isEmpty) {
        throw const FormatException('不支援的設定或修正動作');
      }
      changes[settings.first] = values.first;
    }
    if (changes.isEmpty && clarification == null) {
      throw const FormatException('沒有修正項目或待澄清事項');
    }
    return IntentPatch(
      changes: changes,
      clarification: clarification as String?,
    );
  }
}

// jsonDecode 對重複 key 採最後一項，會隱藏較早的非法值；明確拒絕歧義。
// 這裡只掃已通過 jsonDecode 的合法 JSON token，不另行修復或解讀 JSON。
void _rejectDuplicateObjectKeys(String raw) {
  final containers = <Set<String>?>[];
  var index = 0;
  while (index < raw.length) {
    final character = raw[index];
    if (character == '{') {
      containers.add(<String>{});
    } else if (character == '[') {
      containers.add(null);
    } else if (character == '}' || character == ']') {
      containers.removeLast();
    } else if (character == '"') {
      final start = index++;
      while (raw[index] != '"') {
        if (raw[index] == r'\') index++;
        index++;
      }
      var next = index + 1;
      while (next < raw.length && raw[next].trim().isEmpty) {
        next++;
      }
      if (next < raw.length && raw[next] == ':') {
        final key = jsonDecode(raw.substring(start, index + 1)) as String;
        if (!containers.last!.add(key)) {
          throw const FormatException('JSON 不得有重複欄位');
        }
      }
    }
    index++;
  }
}

class ExecutionReceipt {
  ExecutionReceipt({
    required this.success,
    required this.message,
    this.simulated = false,
    Map<CabinSetting, int> state = const {},
    Map<CabinSetting, Map<String, dynamic>> items = const {},
    Map<String, dynamic>? executionContext,
  }) : state = Map.unmodifiable(state),
       executionContext = executionContext == null
           ? null
           : Map<String, dynamic>.unmodifiable(executionContext),
       items = Map.unmodifiable({
         for (final entry in items.entries)
           entry.key: Map<String, dynamic>.unmodifiable(entry.value),
       });

  final bool success;
  final String message;
  final bool simulated;
  final Map<CabinSetting, int> state;
  final Map<CabinSetting, Map<String, dynamic>> items;
  final Map<String, dynamic>? executionContext;

  Map<String, dynamic> toJson() => {
    'success': success,
    'message': message,
    'simulated': simulated,
    'state': {for (final e in state.entries) e.key.name: e.value},
    if (executionContext != null) 'execution_context': executionContext,
    if (items.isNotEmpty)
      'items': {for (final entry in items.entries) entry.key.name: entry.value},
  };
}

class RepairSnapshot {
  RepairSnapshot({
    this.taskId,
    this.revision = 0,
    this.phase = RepairPhase.idle,
    Map<CabinSetting, RequestedChange> pending = const {},
    this.clarification,
    String? unresolvedText,
    this.result,
    this.error,
    this.patchSource,
  }) : pending = Map.unmodifiable(pending),
       unresolvedText = unresolvedText == null
           ? null
           : String.fromCharCodes(unresolvedText.runes.take(500));

  final String? taskId;
  final int revision;
  final RepairPhase phase;
  final Map<CabinSetting, RequestedChange> pending;
  final String? clarification;

  /// 只保留引發目前澄清的原句，不累積完整對話歷史。
  final String? unresolvedText;
  final ExecutionReceipt? result;
  final String? error;

  /// 最近一次解析結果的來源（'local'／'cloud'）；只在解析剛完成的快照上有值。
  final String? patchSource;

  Map<String, dynamic> toJson() => {
    'task_id': taskId,
    'revision': revision,
    'phase': phase.name,
    'pending': {for (final e in pending.entries) e.key.name: e.value.name},
    'clarification': clarification,
    'unresolved_text': unresolvedText,
    'result': result?.toJson(),
    'error': error,
    if (patchSource != null) 'patch_source': patchSource,
  };
}

typedef IntentParser =
    Future<IntentPatch> Function(String text, RepairSnapshot snapshot);
typedef CabinActuator =
    Future<ExecutionReceipt> Function(
      Map<CabinSetting, RequestedChange> changes,
      String commandId,
    );

class RepairController extends ChangeNotifier {
  RepairController({
    required IntentParser parser,
    required CabinActuator actuator,
    this.parseTimeout = const Duration(seconds: 15),
    this.executionTimeout = const Duration(seconds: 8),
    this.executionContext,
  }) : _parser = parser,
       _actuator = actuator;

  final IntentParser _parser;
  final CabinActuator _actuator;
  final Duration parseTimeout;
  final Duration executionTimeout;

  /// C binds the ACK to the admitted cabin, without binding attention epochs:
  /// an alert after dispatch must not invalidate a genuine late receipt.
  final Map<String, dynamic> Function()? executionContext;
  RepairSnapshot _snapshot = RepairSnapshot();
  RepairSnapshot get snapshot => _snapshot;
  int _taskNumber = 0;
  int _requestNumber = 0;
  bool _disposed = false;
  RepairSnapshot? _parseBase;

  /// Optional authority gate installed by the two-seat collaboration layer.
  /// The original single-device controller remains unchanged when absent.
  bool Function(String taskId, int revision)? confirmationGuard;

  bool get _executionLocked =>
      _snapshot.phase == RepairPhase.executing ||
      _snapshot.phase == RepairPhase.indeterminate;

  /// Only a settled session can be replaced. Unknown execution cannot be reset.
  bool resetForSession() {
    if (_disposed ||
        !const {
          RepairPhase.idle,
          RepairPhase.completed,
          RepairPhase.cancelled,
        }.contains(_snapshot.phase)) {
      return false;
    }
    ++_requestNumber;
    _parseBase = null;
    _publish(RepairSnapshot());
    return true;
  }

  void _publish(RepairSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    if (value.phase != RepairPhase.parsing) _parseBase = null;
    notifyListeners();
  }

  /// 執行中或回報未知時不接受新任務，以免重複修改實體狀態。
  Future<bool> newTask(String text) async {
    if (_disposed || _executionLocked || text.trim().isEmpty) return false;
    final taskId =
        'repair_${DateTime.now().microsecondsSinceEpoch}_${++_taskNumber}';
    final base = RepairSnapshot(taskId: taskId, revision: 1);
    return _parse(text.trim(), base);
  }

  Future<bool> revise(String text, {bool Function()? acceptanceGuard}) async {
    if (_disposed ||
        _executionLocked ||
        text.trim().isEmpty ||
        _snapshot.taskId == null ||
        _snapshot.phase == RepairPhase.completed ||
        _snapshot.phase == RepairPhase.cancelled) {
      return false;
    }
    final base = RepairSnapshot(
      taskId: _snapshot.taskId,
      revision: _snapshot.revision + 1,
      pending: _snapshot.pending,
      clarification: _snapshot.clarification,
      unresolvedText: _snapshot.unresolvedText,
      result: _snapshot.result,
    );
    return _parse(text.trim(), base, acceptanceGuard: acceptanceGuard);
  }

  Future<bool> _parse(
    String text,
    RepairSnapshot base, {
    bool Function()? acceptanceGuard,
  }) async {
    final request = ++_requestNumber;
    _parseBase = base;
    _publish(
      RepairSnapshot(
        taskId: base.taskId,
        revision: base.revision,
        phase: RepairPhase.parsing,
        pending: base.pending,
        clarification: base.clarification,
        unresolvedText: base.unresolvedText,
        result: base.result,
      ),
    );
    bool current() => !_disposed && request == _requestNumber;
    try {
      final patch = await _parser(text, base).timeout(parseTimeout);
      if (!current()) return false;
      if (acceptanceGuard != null && !acceptanceGuard()) {
        invalidatePendingParse();
        return false;
      }
      // 在既有任務上套差異；未提到的欄位原封不動。
      final pending = Map<CabinSetting, RequestedChange>.of(base.pending);
      for (final entry in patch.changes.entries) {
        if (entry.value == RequestedChange.remove) {
          pending.remove(entry.key);
        } else {
          pending[entry.key] = entry.value;
        }
      }
      // 既有需求被全部移除是完成取消，不應逼使用者再提出一項需求。
      // 首次對不存在項目說 remove 仍缺少上下文，需澄清。
      final cancelledAll =
          base.pending.isNotEmpty &&
          pending.isEmpty &&
          patch.clarification == null;
      final clarification =
          patch.clarification ??
          (pending.isEmpty && !cancelledAll ? '目前沒有待執行項目，請說明想調整什麼。' : null);
      _publish(
        RepairSnapshot(
          taskId: base.taskId,
          revision: base.revision,
          phase: cancelledAll
              ? RepairPhase.cancelled
              : (clarification == null
                    ? RepairPhase.awaitingConfirmation
                    : RepairPhase.awaitingClarification),
          pending: pending,
          clarification: clarification,
          unresolvedText: clarification == null
              ? null
              : (patch.unresolvedTextOverride ?? base.unresolvedText ?? text),
          result: base.result,
          patchSource: patch.source,
        ),
      );
      return true;
    } catch (e) {
      if (!current()) return false;
      _publish(
        RepairSnapshot(
          taskId: base.taskId,
          revision: base.revision,
          phase: RepairPhase.failed,
          pending: base.pending,
          clarification: base.clarification,
          unresolvedText: base.unresolvedText,
          result: base.result,
          error: e is TimeoutException
              ? '理解逾時，尚未執行；可以局部重說或取消。'
              : '無法可靠理解，尚未執行；可以局部重說或取消。',
        ),
      );
      return false;
    }
  }

  /// A local, authorized detail edit still uses the same merge and version
  /// rules as model patches. It never executes the actuator.
  bool applyPatch(IntentPatch patch) {
    final before = _snapshot;
    if (_disposed ||
        _executionLocked ||
        before.taskId == null ||
        before.phase == RepairPhase.completed ||
        before.phase == RepairPhase.cancelled ||
        (patch.changes.isEmpty && patch.clarification == null)) {
      return false;
    }
    ++_requestNumber;
    final pending = Map<CabinSetting, RequestedChange>.of(before.pending);
    for (final entry in patch.changes.entries) {
      if (entry.value == RequestedChange.remove) {
        pending.remove(entry.key);
      } else {
        pending[entry.key] = entry.value;
      }
    }
    final cancelledAll =
        before.pending.isNotEmpty &&
        pending.isEmpty &&
        patch.clarification == null;
    final clarification =
        patch.clarification ??
        (pending.isEmpty && !cancelledAll ? '目前沒有待執行項目，請說明想調整什麼。' : null);
    _publish(
      RepairSnapshot(
        taskId: before.taskId,
        revision: before.revision + 1,
        phase: cancelledAll
            ? RepairPhase.cancelled
            : (clarification == null
                  ? RepairPhase.awaitingConfirmation
                  : RepairPhase.awaitingClarification),
        pending: pending,
        clarification: clarification,
        unresolvedText: clarification == null
            ? null
            : (patch.unresolvedTextOverride ?? before.unresolvedText),
        result: before.result,
      ),
    );
    return true;
  }

  /// Revoking a lease invalidates an unfinished edit, not the previously
  /// proposed task. Its revision changes so an old driver confirmation fails.
  bool invalidatePendingParse() {
    if (_disposed || _snapshot.phase != RepairPhase.parsing) return false;
    final before = _snapshot;
    final base = _parseBase ?? before;
    ++_requestNumber;
    _publish(
      RepairSnapshot(
        taskId: before.taskId,
        revision: before.revision + 1,
        phase: base.clarification != null
            ? RepairPhase.awaitingClarification
            : (base.pending.isNotEmpty
                  ? RepairPhase.awaitingConfirmation
                  : RepairPhase.failed),
        pending: base.pending,
        clarification: base.clarification,
        unresolvedText: base.unresolvedText,
        result: base.result,
        error: '修正授權已結束；先前需求保留，尚未執行。',
      ),
    );
    return true;
  }

  bool cancel() {
    if (_disposed ||
        _executionLocked ||
        _snapshot.taskId == null ||
        _snapshot.phase == RepairPhase.completed ||
        _snapshot.phase == RepairPhase.cancelled) {
      return false;
    }
    ++_requestNumber; // 使已排隊或正在推論的結果失效。
    _publish(
      RepairSnapshot(
        taskId: _snapshot.taskId,
        revision: _snapshot.revision + 1,
        phase: RepairPhase.cancelled,
        result: _snapshot.result,
      ),
    );
    return true;
  }

  Future<bool> confirm(String taskId, int revision) async {
    final before = _snapshot;
    if (_disposed ||
        before.taskId != taskId ||
        before.revision != revision ||
        before.phase != RepairPhase.awaitingConfirmation ||
        before.clarification != null ||
        before.pending.isEmpty ||
        (confirmationGuard != null && !confirmationGuard!(taskId, revision))) {
      return false;
    }
    final admittedContext = executionContext == null
        ? null
        : Map<String, dynamic>.unmodifiable(executionContext!());
    // 在呼叫 adapter 前切換階段；連點或重送同一確認都不會再次執行。
    _publish(
      RepairSnapshot(
        taskId: taskId,
        revision: revision,
        phase: RepairPhase.executing,
        pending: before.pending,
        result: before.result,
      ),
    );
    final commandId = admittedContext == null
        ? '$taskId:$revision'
        : '${admittedContext['cabin_session_id']}:$taskId:$revision';
    bool active() =>
        !_disposed &&
        _snapshot.taskId == taskId &&
        _snapshot.revision == revision &&
        (_snapshot.phase == RepairPhase.executing ||
            _snapshot.phase == RepairPhase.indeterminate);
    void acknowledge(ExecutionReceipt receipt) {
      if (!active()) return;
      // Structured receipts must account for every requested setting. A
      // contradictory or incomplete ACK cannot establish what really ran.
      if (!_consistentReceipt(receipt, before.pending) ||
          (admittedContext != null &&
              (receipt.items.isEmpty ||
                  !_sameExecutionContext(
                    admittedContext,
                    receipt.executionContext,
                  )))) {
        _publish(
          RepairSnapshot(
            taskId: taskId,
            revision: revision,
            phase: RepairPhase.indeterminate,
            pending: before.pending,
            result: before.result,
            error: '執行回報不完整或互相矛盾；請查證，不會自動重送。',
          ),
        );
        return;
      }
      final remaining = Map<CabinSetting, RequestedChange>.of(before.pending);
      if (!receipt.success && receipt.items.isNotEmpty) {
        remaining.removeWhere(
          (setting, _) => receipt.items[setting]!['success'] == true,
        );
      }
      // A retry may contain only the unexecuted settings. Retain earlier
      // successful ACKs, but not failed settings removed from the new proposal.
      final priorItems = before.result?.items ?? const {};
      final finalState = <CabinSetting, int>{...?before.result?.state};
      for (final setting in before.pending.keys) {
        // A legacy atomic ACK without a new value cannot make an old value
        // current. Structured item.after is already validated and authoritative.
        if (!receipt.state.containsKey(setting) &&
            !receipt.items.containsKey(setting)) {
          finalState.remove(setting);
        }
      }
      finalState.addAll(receipt.state);
      for (final entry in receipt.items.entries) {
        finalState[entry.key] = entry.value['after'] as int;
      }
      final combinedReceipt = ExecutionReceipt(
        success: receipt.success,
        message: receipt.message,
        simulated:
            receipt.simulated &&
            (before.result == null || before.result!.simulated),
        state: finalState,
        items: {
          for (final entry in priorItems.entries)
            if (entry.value['success'] == true &&
                !before.pending.containsKey(entry.key))
              entry.key: entry.value,
          ...receipt.items,
        },
        executionContext: receipt.executionContext,
      );
      _publish(
        RepairSnapshot(
          taskId: taskId,
          revision: revision,
          phase: receipt.success ? RepairPhase.completed : RepairPhase.failed,
          pending: receipt.success ? before.pending : remaining,
          result: combinedReceipt,
          error: receipt.success ? null : receipt.message,
        ),
      );
    }

    Future<ExecutionReceipt>? execution;
    try {
      execution = _actuator(before.pending, commandId);
      final receipt = await execution.timeout(executionTimeout);
      acknowledge(receipt);
      return _snapshot.phase == RepairPhase.completed;
    } catch (_) {
      if (!active()) return false;
      _publish(
        RepairSnapshot(
          taskId: taskId,
          revision: revision,
          phase: RepairPhase.indeterminate,
          pending: before.pending,
          result: before.result,
          error: '執行回報尚未確認；不會宣稱完成或自動重送。',
        ),
      );
      // timeout 不代表 adapter 撤回了動作；晚到的 ACK 仍可澄清真實結果。
      if (execution != null) {
        unawaited(execution.then(acknowledge, onError: (Object _) {}));
      }
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_requestNumber;
    super.dispose();
  }
}

/// Legacy atomic ACKs without items remain supported. Adapters that can
/// partially execute must supply complete item receipts; failed items explicitly
/// certify that their value did not change. Unknown effects cannot be retried.
bool _consistentReceipt(
  ExecutionReceipt receipt,
  Map<CabinSetting, RequestedChange> requested,
) {
  if (receipt.items.isEmpty) return true;
  if (receipt.items.length != requested.length ||
      requested.keys.any((setting) => !receipt.items.containsKey(setting))) {
    return false;
  }
  for (final entry in requested.entries) {
    final item = receipt.items[entry.key]!;
    final before = item['before'];
    final after = item['after'];
    final success = item['success'];
    final limit = entry.key == CabinSetting.rearFan ? 7 : 10;
    if (before is! int ||
        after is! int ||
        before < 0 ||
        before > limit ||
        after < 0 ||
        after > limit ||
        success is! bool ||
        item['action'] != entry.value.name ||
        entry.value == RequestedChange.remove ||
        (receipt.state.containsKey(entry.key) &&
            receipt.state[entry.key] != after)) {
      return false;
    }
    final delta = switch (entry.value) {
      RequestedChange.decrease => -1,
      RequestedChange.increase => 1,
      RequestedChange.keep => 0,
      RequestedChange.remove => 0,
    };
    final expected = success ? (before + delta).clamp(0, limit) : before;
    if (after != expected) return false;
  }
  return receipt.success ==
      receipt.items.values.every((item) => item['success'] == true);
}

bool _sameExecutionContext(
  Map<String, dynamic> expected,
  Map<String, dynamic>? actual,
) =>
    actual != null &&
    expected.length == 3 &&
    expected['cabin_session_id'] is String &&
    expected['profile_id'] is String &&
    expected['profile_revision'] is int &&
    actual.length == expected.length &&
    expected.entries.every((entry) => actual[entry.key] == entry.value);

/// 僅修改記憶體，不接 CAN、真冷氣或車用音響。
class MockCabinActuator {
  MockCabinActuator({
    int rearFan = 3,
    int mediaVolume = 5,
    int navVolume = 5,
    this.supports,
    this.executionContext,
  }) : _state = {
         CabinSetting.rearFan: rearFan,
         CabinSetting.mediaVolume: mediaVolume,
         CabinSetting.navVolume: navVolume,
       };

  final Map<CabinSetting, int> _state;
  final Map<String, ExecutionReceipt> _receipts = {};
  final Map<String, String> _fingerprints = {};
  final bool Function(CabinSetting)? supports;
  final Map<String, dynamic> Function()? executionContext;
  int executeCount = 0;
  Map<CabinSetting, int> get state => Map.unmodifiable(_state);

  /// Host calls this only AFTER a successful clean parked session replacement.
  void reset() {
    _state
      ..[CabinSetting.rearFan] = 3
      ..[CabinSetting.mediaVolume] = 5
      ..[CabinSetting.navVolume] = 5;
    _receipts.clear();
    _fingerprints.clear();
    executeCount = 0;
  }

  Future<ExecutionReceipt> call(
    Map<CabinSetting, RequestedChange> changes,
    String commandId,
  ) async {
    final context = executionContext?.call();
    final sorted = changes.entries.toList()
      ..sort((a, b) => a.key.name.compareTo(b.key.name));
    final fingerprint = jsonEncode({
      'changes': {for (final entry in sorted) entry.key.name: entry.value.name},
      if (context != null) 'execution_context': context,
    });
    final cached = _receipts[commandId];
    if (cached != null && _fingerprints[commandId] == fingerprint) {
      return cached;
    }
    final unsupported = changes.keys.any(
      (setting) => !(supports?.call(setting) ?? true),
    );
    if (cached != null ||
        commandId.isEmpty ||
        changes.isEmpty ||
        unsupported ||
        changes.values.contains(RequestedChange.remove)) {
      return ExecutionReceipt(
        success: false,
        simulated: true,
        message: unsupported
            ? '本模擬座艙有不支援項目；整批未執行。'
            : cached != null
            ? '同一命令 ID 的內容不一致；未再次執行。'
            : '模擬控制：候選或命令不合法，未執行。',
        state: _state,
        executionContext: context,
        items: {
          for (final entry in changes.entries)
            entry.key: {
              'before': _state[entry.key],
              'after': _state[entry.key],
              'action': entry.value.name,
              'success': false,
            },
        },
      );
    }
    executeCount++;
    final items = <CabinSetting, Map<String, dynamic>>{};
    for (final entry in changes.entries) {
      final before = _state[entry.key]!;
      final delta = switch (entry.value) {
        RequestedChange.decrease => -1,
        RequestedChange.increase => 1,
        RequestedChange.keep => 0,
        RequestedChange.remove => 0,
      };
      final limit = entry.key == CabinSetting.rearFan ? 7 : 10;
      _state[entry.key] = (_state[entry.key]! + delta).clamp(0, limit).toInt();
      items[entry.key] = {
        'before': before,
        'after': _state[entry.key],
        'action': entry.value.name,
        'success': true,
      };
    }
    final receipt = ExecutionReceipt(
      success: true,
      simulated: true,
      message: '模擬控制已完成；未連接真實車輛。',
      state: _state,
      items: items,
      executionContext: context,
    );
    _receipts[commandId] = receipt;
    _fingerprints[commandId] = fingerprint;
    return receipt;
  }
}
