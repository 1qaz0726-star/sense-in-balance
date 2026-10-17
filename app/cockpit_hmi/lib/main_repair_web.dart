import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'cockpit_alert_slot.dart';
import 'cabin_coordination_widgets.dart';
import 'cockpit_design.dart';
import 'cockpit_instruments.dart';
import 'protocol.dart';
import 'repair_collaboration_widgets.dart';
import 'repair_speech.dart';

void main() {
  final b = Uri.base;
  final host =
      b.queryParameters['host'] ?? (b.host.isEmpty ? '127.0.0.1' : b.host);
  final port =
      int.tryParse(b.queryParameters['port'] ?? '') ??
      (b.hasPort ? b.port : 8767);
  runApp(
    MaterialApp(
      title: '不用重講・駕駛顯示',
      debugShowCheckedModeBanner: false,
      theme: CockpitStyle.theme,
      home: RepairMonitor(
        url: Uri(scheme: 'ws', host: host, port: port, path: '/repair'),
      ),
    ),
  );
}

/// Driver summary and explicit controls; it never performs model inference.
class RepairMonitor extends StatefulWidget {
  const RepairMonitor({super.key, required this.url, this.channelFactory});
  final Uri url;
  final WebSocketChannel Function(Uri)? channelFactory;
  @override
  State<RepairMonitor> createState() => _RepairMonitorState();
}

class _RepairMonitorState extends State<RepairMonitor> {
  WebSocketChannel? channel;
  StreamSubscription? subscription;
  Timer? retry, watch, replyWatch;
  Map<String, dynamic>? status;
  DateTime? lastAt;
  bool online = false;
  int generation = 0;
  int selectedView = 1;
  bool safetyActive = false;
  int commandNumber = 0;
  String? pendingCommandId, pendingAction, commandError, commandNotice;
  String? confirmationKey;
  DateTime? lastHeartbeatAt;
  String? previousTaskId;
  Map previousPending = const {};
  Set<String> changedSettings = {};
  final feedback = RepairSpeechFeedback();
  final summaryScroll = ScrollController();
  bool speechBusy = false;
  int speechGeneration = 0;
  String? speechNotice;

  bool get isDriver => frameFresh && status?['role'] == 'driver';
  Map? get cabinContext {
    if (status?['schema'] != 2) return null;
    final value = status?['cabin_context'];
    return value is Map ? value : const {};
  }

  String _confirmationIdentity(Map task) =>
      '${task['task_id']}:${task['revision']}:'
      '${cabinContext?['cabin_session_id']}:${cabinContext?['profile_id']}:'
      '${cabinContext?['profile_revision']}:${cabinContext?['attention_epoch']}';
  bool get validCabinContext {
    if (status?['schema'] != 2) return true;
    final c = cabinContext;
    return c?['cabin_session_id'] is String &&
        '${c?['cabin_session_id']}'.isNotEmpty &&
        c?['profile_id'] is String &&
        c?['profile_revision'] is int &&
        c?['attention_epoch'] is int &&
        c?['attention'] is Map &&
        c?['profile'] is Map &&
        c?['capability'] is Map;
  }

  bool get confirmationInFlight {
    final task = status?['task'];
    return task is Map &&
        task['phase'] == 'awaitingConfirmation' &&
        confirmationKey == _confirmationIdentity(task);
  }

  bool get frameFresh =>
      online &&
      lastAt != null &&
      DateTime.now().difference(lastAt!) < const Duration(seconds: 3);

  // An urgent event takes priority when it begins. Its changing heartbeat IDs
  // must not repeatedly pull the user out of the collaboration results view.
  void trackSafetyTransition() {
    final event = _parseCockpitEvent(status?['cockpit_event']);
    final urgent =
        (frameFresh && cabinAttentionBlocked(cabinContext)) ||
        _cockpitEventFresh(event, frameFresh) &&
            event!.decision.urgency == Urgency.safety;
    if (urgent && !safetyActive) {
      selectedView = 0;
      _stopResultSpeech();
    }
    safetyActive = urgent;
  }

  @override
  void initState() {
    super.initState();
    watch = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (online &&
          lastAt != null &&
          DateTime.now().difference(lastAt!) >= const Duration(seconds: 3)) {
        lost();
      } else {
        setState(trackSafetyTransition);
        if (isDriver &&
            (lastHeartbeatAt == null ||
                DateTime.now().difference(lastHeartbeatAt!) >=
                    const Duration(seconds: 2))) {
          lastHeartbeatAt = DateTime.now();
          sendCommand('heartbeat');
        }
      }
    });
    unawaited(connect());
  }

  Future<void> connect() async {
    final attempt = ++generation;
    retry?.cancel();
    // A silent peer may never answer the close handshake. Do not let an old
    // connection delay recovery; generation prevents its callbacks resurfacing.
    unawaited(subscription?.cancel());
    _closeQuietly(channel);
    subscription = null;
    channel = null;
    WebSocketChannel? opened;
    try {
      final ch =
          widget.channelFactory?.call(widget.url) ??
          WebSocketChannel.connect(widget.url);
      opened = ch;
      await ch.ready.timeout(const Duration(seconds: 4));
      if (!mounted || attempt != generation) {
        _closeQuietly(ch);
        return;
      }
      channel = ch;
      subscription = ch.stream.listen(
        (raw) {
          try {
            final m = jsonDecode('$raw');
            if (attempt == generation &&
                m is Map &&
                m['type'] == 'repair_reply') {
              if (m['accepted'] is! bool ||
                  m['command_id'] != pendingCommandId) {
                return;
              }
              if (mounted) {
                setState(() {
                  final action = pendingAction;
                  replyWatch?.cancel();
                  pendingCommandId = null;
                  pendingAction = null;
                  commandError = m['accepted'] == true
                      ? null
                      : '${m['error'] ?? '操作未受理。'}';
                  if ((action == 'confirm' || action == 'resume_confirm') &&
                      m['accepted'] != true) {
                    confirmationKey = null;
                  }
                  commandNotice = m['accepted'] == true
                      ? switch (action) {
                          'pair_driver' => '配對已受理；身分以最新同步為準。',
                          'grant' => '授權已受理；乘客可修改本次需求。',
                          'revoke' => '收回授權已受理。',
                          'confirm' => '確認已受理，等待模擬執行回報。',
                          'resume_confirm' => '最新需求已確認，等待模擬執行回報。',
                          'cancel' => '取消已受理；狀態以最新同步為準。',
                          _ => null,
                        }
                      : null;
                });
              }
              return;
            }
            if (attempt == generation &&
                m is Map &&
                m['type'] == 'repair_status' &&
                (m['schema'] == 1 || m['schema'] == 2) &&
                m['task'] is Map) {
              if (mounted) {
                final previousTask = status?['task'];
                final previousSpeechIdentity = _completedSpeechIdentity();
                final nextTask = m['task'] as Map;
                final becameDriver =
                    status?['role'] != 'driver' && m['role'] == 'driver';
                final taskChanged =
                    previousTask is Map &&
                    previousTask['task_id'] != nextTask['task_id'];
                final resultArrived =
                    nextTask['phase'] == 'completed' &&
                    (previousTask is! Map ||
                        previousTask['phase'] != 'completed');
                final previousContext = cabinContext;
                final nextContext = m['cabin_context'];
                final sessionChanged =
                    previousContext is Map &&
                    nextContext is Map &&
                    previousContext['cabin_session_id'] !=
                        nextContext['cabin_session_id'];
                setState(() {
                  if (!online && commandError == '連線中斷；恢復後請重新配對。') {
                    commandError = null;
                    commandNotice = '連線已恢復，請重新配對後操作。';
                  }
                  status = Map<String, dynamic>.from(m);
                  if (sessionChanged) {
                    pendingCommandId = null;
                    pendingAction = null;
                    confirmationKey = null;
                    lastHeartbeatAt = null;
                    commandError = null;
                    commandNotice = '能力設定已切換，請重新配對。';
                    replyWatch?.cancel();
                  }
                  _capturePendingChanges();
                  lastAt = DateTime.now();
                  online = true;
                  trackSafetyTransition();
                  if (taskChanged ||
                      sessionChanged ||
                      previousSpeechIdentity != _completedSpeechIdentity()) {
                    _stopResultSpeech();
                  }
                });
                if (becameDriver || taskChanged || resultArrived) {
                  _returnToSummaryTop();
                }
              }
            }
          } catch (_) {
            /* Invalid frames never change displayed task state. */
          }
        },
        onDone: () {
          if (attempt == generation) lost();
        },
        onError: (_) {
          if (attempt == generation) lost();
        },
      );
    } catch (_) {
      _closeQuietly(opened);
      if (attempt == generation) lost();
    }
  }

  void _returnToSummaryTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && selectedView == 1 && summaryScroll.hasClients) {
        summaryScroll.jumpTo(0);
      }
    });
  }

  void lost() {
    if (!mounted) return;
    ++generation;
    _stopResultSpeech();
    unawaited(subscription?.cancel());
    _closeQuietly(channel);
    subscription = null;
    channel = null;
    replyWatch?.cancel();
    setState(() {
      online = false;
      safetyActive = false;
      status = null;
      pendingCommandId = null;
      pendingAction = null;
      confirmationKey = null;
      lastHeartbeatAt = null;
      changedSettings = {};
      previousTaskId = null;
      previousPending = const {};
      commandNotice = null;
      commandError = '連線中斷；恢復後請重新配對。';
      speechNotice = null;
    });
    _returnToSummaryTop();
    retry?.cancel();
    retry = Timer(const Duration(seconds: 2), connect);
  }

  @override
  void dispose() {
    ++generation;
    ++speechGeneration;
    retry?.cancel();
    watch?.cancel();
    replyWatch?.cancel();
    unawaited(subscription?.cancel());
    _closeQuietly(channel);
    summaryScroll.dispose();
    unawaited(feedback.stop().catchError((Object _) {}));
    super.dispose();
  }

  void _capturePendingChanges() {
    final task = status?['task'];
    if (task is! Map) return;
    final next = task['pending'] is Map ? task['pending'] as Map : const {};
    if (task['phase'] != 'awaitingConfirmation' ||
        confirmationKey != _confirmationIdentity(task)) {
      confirmationKey = null;
    }
    if (task['task_id'] != previousTaskId) {
      changedSettings = {};
      commandError = null;
      speechNotice = null;
    } else if (task['phase'] != 'parsing') {
      final changes = {
        for (final setting in ['rearFan', 'mediaVolume', 'navVolume'])
          if (previousPending[setting] != next[setting]) setting,
      };
      if (changes.isNotEmpty) changedSettings = changes;
    }
    previousTaskId = task['task_id'] is String
        ? task['task_id'] as String
        : null;
    previousPending = Map.of(next);
    if (task['phase'] == 'completed' || task['phase'] == 'cancelled') {
      commandNotice = null;
    }
  }

  void sendCommand(String action, {String? pairingCode}) {
    if (!frameFresh ||
        !validCabinContext ||
        channel == null ||
        (action != 'heartbeat' && pendingCommandId != null)) {
      return;
    }
    if (action != 'pair_driver' && !isDriver) return;
    final confirming = action == 'confirm' || action == 'resume_confirm';
    if (confirming && confirmationInFlight) return;
    final payload = <String, dynamic>{
      'type': 'repair_command',
      'command_id':
          'driver_${DateTime.now().microsecondsSinceEpoch}_${++commandNumber}',
      'action': action,
      if (status?['schema'] == 2)
        'cabin_session_id': cabinContext!['cabin_session_id'],
    };
    if (action == 'pair_driver') {
      if (pairingCode == null || !RegExp(r'^\d{6}$').hasMatch(pairingCode)) {
        return;
      }
      payload['pairing_code'] = pairingCode;
    } else if (action != 'heartbeat') {
      final task = status?['task'];
      if (task is! Map ||
          task['task_id'] is! String ||
          task['revision'] is! int) {
        return;
      }
      if (confirming && task['phase'] != 'awaitingConfirmation') {
        return;
      }
      payload['task_id'] = task['task_id'];
      payload['revision'] = task['revision'];
      if (status?['schema'] == 2) {
        payload['profile_id'] = cabinContext!['profile_id'];
        payload['profile_revision'] = cabinContext!['profile_revision'];
        payload['attention_epoch'] = cabinContext!['attention_epoch'];
      }
    }
    try {
      if (action != 'heartbeat') {
        setState(() {
          pendingCommandId = payload['command_id'] as String;
          pendingAction = action;
          if (confirming) {
            confirmationKey = _confirmationIdentity(status!['task'] as Map);
          }
          commandError = null;
          commandNotice = '操作已送出，等待主控回覆。';
        });
      }
      channel!.sink.add(jsonEncode(payload));
      if (action != 'heartbeat') {
        replyWatch?.cancel();
        replyWatch = Timer(const Duration(seconds: 10), () {
          if (!mounted || pendingCommandId != payload['command_id']) return;
          setState(() {
            pendingCommandId = null;
            pendingAction = null;
            commandNotice = null;
            commandError = '尚未收到操作回覆；請以最新摘要為準，不會自動重送。';
          });
        });
      }
    } catch (_) {
      lost();
    }
  }

  String? _completedResultText() {
    if (!frameFresh || cabinAttentionBlocked(cabinContext)) return null;
    final task = status?['task'];
    if (task is! Map) return null;
    final state = completedSimulatedCabinState(
      task,
      cabinContext: cabinContext,
    );
    if (state == null) return null;
    final fan = _readLevel(state, 'rearFan', 7);
    final music = _readLevel(state, 'mediaVolume', 10);
    final navigation = _readLevel(state, 'navVolume', 10);
    if (music == null ||
        navigation == null ||
        (cabinSettingReadable(cabinContext, 'rearFan') && fan == null)) {
      return null;
    }
    return '模擬設定已套用。'
        '${cabinSettingReadable(cabinContext, 'rearFan') ? '後座風量$fan，' : '此車未提供後座風量介面，'}'
        '音樂音量$music，導航音量$navigation。';
  }

  /// A result narration belongs to one validated receipt, never just a fresh
  /// socket. Profile/task replacement invalidates any pending async TTS work.
  String? _completedSpeechIdentity() {
    if (!frameFresh || cabinAttentionBlocked(cabinContext)) return null;
    final task = status?['task'];
    if (task is! Map) return null;
    final state = completedSimulatedCabinState(
      task,
      cabinContext: cabinContext,
    );
    if (state == null) return null;
    final result = task['result'];
    final execution = result is Map ? result['execution_context'] : null;
    return jsonEncode({
      'task_id': task['task_id'],
      'revision': task['revision'],
      'schema': status?['schema'],
      'execution_context': execution is Map
          ? {
              'cabin_session_id': execution['cabin_session_id'],
              'profile_id': execution['profile_id'],
              'profile_revision': execution['profile_revision'],
            }
          : null,
      'state': state,
    });
  }

  void _stopResultSpeech() {
    ++speechGeneration;
    speechBusy = false;
    speechNotice = null;
    unawaited(feedback.stop().catchError((Object _) {}));
  }

  Future<void> _speakResult() async {
    final text = _completedResultText();
    final identity = _completedSpeechIdentity();
    if (text == null || identity == null || speechBusy) return;
    final request = ++speechGeneration;
    bool current() =>
        mounted &&
        request == speechGeneration &&
        _completedSpeechIdentity() == identity;
    setState(() {
      speechBusy = true;
      speechNotice = null;
    });
    try {
      final available = await feedback.speak(text, allowed: current);
      if (current()) {
        speechNotice = available ? '已使用本機離線語音播報模擬回報。' : '離線語音尚未就緒，請閱讀文字結果。';
      }
    } catch (_) {
      if (current()) speechNotice = '無法使用本機離線語音，請閱讀文字結果。';
    } finally {
      if (mounted && request == speechGeneration) {
        setState(() => speechBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fresh = frameFresh;
    final cockpitEvent = _parseCockpitEvent(status?['cockpit_event']);
    final cockpitFresh = _cockpitEventFresh(cockpitEvent, fresh);
    final task = status?['task'] as Map? ?? const {};
    final result = task['result'] as Map?;
    final phase = task['phase'];
    final completed =
        fresh &&
        completedSimulatedCabinState(task, cabinContext: cabinContext) != null;
    // Once freshness is lost, neither a previous receipt nor cached cabin state
    // is presented as current. The reconnecting shell stays visible on its own.
    final cabinState = !fresh || phase == 'indeterminate'
        ? null
        : status?['cabin_state'] is Map
        ? status!['cabin_state'] as Map
        : result?['state'] is Map
        ? result!['state'] as Map
        : null;
    final collaboration = fresh && status?['collaboration'] is Map
        ? status!['collaboration'] as Map
        : const {};
    return Scaffold(
      backgroundColor: CockpitStyle.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 700;
            final shortLandscape = wide && constraints.maxHeight < 560;
            final padding = shortLandscape
                ? const EdgeInsets.symmetric(horizontal: 24, vertical: 14)
                : EdgeInsets.all(wide ? 32 : 22);
            final statusPanel = DriverCollaborationPanel(
              task: task,
              collaboration: collaboration,
              fresh: fresh,
              driver: isDriver,
              commandPending: pendingCommandId != null || confirmationInFlight,
              changedSettings: changedSettings,
              commandError: commandError,
              commandNotice: commandNotice,
              onPair: (code) => sendCommand('pair_driver', pairingCode: code),
              onAction: sendCommand,
              onSpeak: _completedResultText() == null ? null : _speakResult,
              speechBusy: speechBusy,
              speechNotice: speechNotice,
              cabinContext: cabinContext,
            );
            final viewSwitch = _MonitorViews(
              selected: selectedView,
              onSelected: (value) {
                setState(() => selectedView = value);
                if (value == 1) _returnToSummaryTop();
              },
            );
            return Padding(
              padding: padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (shortLandscape)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: _MonitorHeader(
                            fresh: cockpitFresh,
                            gear: _readGear(cockpitEvent, cockpitFresh),
                            compact: true,
                          ),
                        ),
                        const SizedBox(width: 28),
                        SizedBox(width: 310, child: viewSwitch),
                      ],
                    )
                  else
                    _MonitorHeader(
                      fresh: cockpitFresh,
                      gear: _readGear(cockpitEvent, cockpitFresh),
                    ),
                  SizedBox(height: shortLandscape ? 10 : 14),
                  // Alert content changes inside a reserved slot. Normal,
                  // urgent and unknown states keep the same body constraints,
                  // so the instrument does not resize as a warning arrives.
                  CockpitAlertSlot(
                    event: cockpitEvent,
                    fresh: cockpitFresh,
                    compact: shortLandscape,
                  ),
                  SizedBox(height: shortLandscape ? 10 : 14),
                  if (!shortLandscape) ...[
                    viewSwitch,
                    const SizedBox(height: 18),
                  ],
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, bodyConstraints) {
                        final panelHeight = shortLandscape
                            ? bodyConstraints.maxHeight
                            : bodyConstraints.maxHeight
                                  .clamp(380.0, double.infinity)
                                  .toDouble();
                        return SingleChildScrollView(
                          key: ValueKey('monitor_view_$selectedView'),
                          controller: selectedView == 1 ? summaryScroll : null,
                          child: selectedView == 0
                              ? CockpitInstrumentPanel(
                                  event: cockpitEvent,
                                  fresh: cockpitFresh,
                                  height: panelHeight,
                                )
                              : completed || cabinAttentionBlocked(cabinContext)
                              ? statusPanel
                              : wide
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(flex: 5, child: statusPanel),
                                    const SizedBox(width: 48),
                                    Expanded(
                                      flex: 4,
                                      child: _MonitorLevels(
                                        state: cabinState,
                                        wide: false,
                                        cabinContext: cabinContext,
                                      ),
                                    ),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    statusPanel,
                                    const SizedBox(height: 36),
                                    _MonitorLevels(
                                      state: cabinState,
                                      wide: false,
                                      cabinContext: cabinContext,
                                    ),
                                  ],
                                ),
                        );
                      },
                    ),
                  ),
                  if (cabinContext != null)
                    CabinAttentionStrip(
                      contextData: cabinContext,
                      completed: completed,
                      onViewSummary: () {
                        setState(() => selectedView = 1);
                        _returnToSummaryTop();
                      },
                    ),
                  SizedBox(height: shortLandscape ? 8 : 12),
                  const Text(
                    '配對與授權為實作 · 行車訊號與車控為模擬',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: CockpitStyle.muted,
                      fontSize: 11,
                      fontVariations: [ui.FontVariation('wght', 400)],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

void _closeQuietly(WebSocketChannel? channel) {
  if (channel == null) return;
  unawaited(channel.sink.close().then<void>((_) {}, onError: (Object _) {}));
}

Envelope? _parseCockpitEvent(Object? raw) {
  try {
    return Envelope.fromJson(raw);
  } catch (_) {
    // Optional legacy event payloads are isolated from the repair connection.
    // Malformed or unknown events cannot replace a healthy collaboration view.
    return null;
  }
}

bool _cockpitEventFresh(Envelope? event, bool frameFresh) {
  if (!frameFresh ||
      event == null ||
      event.availability != Avail.ok ||
      !event.ts.isFinite ||
      event.ts <= 0) {
    return false;
  }
  final age = DateTime.now().millisecondsSinceEpoch / 1000 - event.ts;
  return age >= 0 && age <= 3;
}

String _readGear(Envelope? event, bool fresh) {
  if (!fresh || event == null) return '—';
  final gear = '${event.vehicle?['gear'] ?? event.state['gear'] ?? ''}'
      .toUpperCase();
  return const {'P', 'R', 'N', 'D'}.contains(gear) ? gear : '—';
}

class _MonitorViews extends StatelessWidget {
  const _MonitorViews({required this.selected, required this.onSelected});
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var index = 0; index < 2; index++)
        Expanded(
          child: Semantics(
            button: true,
            selected: selected == index,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onSelected(index),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: selected == index
                            ? CockpitStyle.accent
                            : CockpitStyle.line,
                        width: selected == index ? 1.5 : .5,
                      ),
                    ),
                  ),
                  child: Text(
                    index == 0 ? '行車儀表' : '需求摘要',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected == index
                          ? CockpitStyle.text
                          : CockpitStyle.muted,
                      fontSize: 13,
                      fontVariations: const [ui.FontVariation('wght', 500)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _MonitorHeader extends StatelessWidget {
  const _MonitorHeader({
    required this.fresh,
    required this.gear,
    this.compact = false,
  });
  final bool fresh;
  final String gear;
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: compact ? 32 : 38,
        child: Text(
          gear,
          style: TextStyle(
            color: CockpitStyle.text,
            fontSize: compact ? 30 : 34,
            height: 1,
            fontVariations: const [ui.FontVariation('wght', 500)],
          ),
        ),
      ),
      Container(width: .5, height: 25, color: CockpitStyle.line),
      const SizedBox(width: 16),
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '駕駛顯示',
            style: TextStyle(
              color: CockpitStyle.text,
              fontSize: 13,
              fontVariations: [ui.FontVariation('wght', 500)],
            ),
          ),
          SizedBox(height: 2),
          Text(
            '授權與最終確認',
            style: TextStyle(
              color: CockpitStyle.muted,
              fontSize: 9,
              letterSpacing: .5,
            ),
          ),
        ],
      ),
      const Spacer(),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const CockpitClock(),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: fresh ? CockpitStyle.accent : CockpitStyle.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                fresh ? '即時同步' : '等待同步',
                style: const TextStyle(color: CockpitStyle.muted, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

class _MonitorLevels extends StatelessWidget {
  const _MonitorLevels({
    required this.state,
    required this.wide,
    this.cabinContext,
  });
  final Map? state;
  final bool wide;
  final Map? cabinContext;

  @override
  Widget build(BuildContext context) {
    final levels = [
      _MonitorLevel(
        label: '後座風量',
        icon: Icons.air_rounded,
        value: cabinSettingReadable(cabinContext, 'rearFan')
            ? _readLevel(state, 'rearFan', 7)
            : null,
        max: 7,
        readable: cabinSettingReadable(cabinContext, 'rearFan'),
      ),
      _MonitorLevel(
        label: '音樂音量',
        icon: Icons.music_note_rounded,
        value: _readLevel(state, 'mediaVolume', 10),
        max: 10,
      ),
      _MonitorLevel(
        label: '導航音量',
        icon: Icons.volume_up_outlined,
        value: _readLevel(state, 'navVolume', 10),
        max: 10,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Text(
              '座艙設定',
              style: TextStyle(
                color: CockpitStyle.text,
                fontSize: 11,
                letterSpacing: .8,
                fontVariations: [ui.FontVariation('wght', 500)],
              ),
            ),
            Spacer(),
            Text(
              '模擬數值',
              style: TextStyle(color: CockpitStyle.muted, fontSize: 10),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Divider(height: .5, thickness: .5, color: CockpitStyle.line),
        const SizedBox(height: 20),
        wide
            ? Row(
                children: [
                  Expanded(child: levels[0]),
                  const SizedBox(width: 34),
                  Expanded(child: levels[1]),
                  const SizedBox(width: 34),
                  Expanded(child: levels[2]),
                ],
              )
            : Column(
                children: [
                  levels[0],
                  const SizedBox(height: 26),
                  levels[1],
                  const SizedBox(height: 26),
                  levels[2],
                ],
              ),
      ],
    );
  }
}

class _MonitorLevel extends StatelessWidget {
  const _MonitorLevel({
    required this.label,
    required this.icon,
    required this.value,
    required this.max,
    this.readable = true,
  });
  final String label;
  final IconData icon;
  final int? value;
  final int max;
  final bool readable;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Icon(icon, size: 15, color: CockpitStyle.muted),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(color: CockpitStyle.muted, fontSize: 13),
          ),
          const Spacer(),
          Text(
            value?.toString() ?? '—',
            style: const TextStyle(
              color: CockpitStyle.text,
              fontSize: 28,
              height: 1,
              fontVariations: [ui.FontVariation('wght', 400)],
            ),
          ),
          const SizedBox(width: 5),
          Text(
            readable ? '/ $max' : '/ 不提供',
            style: const TextStyle(color: CockpitStyle.muted, fontSize: 10),
          ),
        ],
      ),
      const SizedBox(height: 11),
      CabinLevelIndicator(value: value, max: max),
    ],
  );
}

int? _readLevel(Map? state, String name, int max) {
  final value = state?[name];
  return value is int && value >= 0 && value <= max ? value : null;
}
