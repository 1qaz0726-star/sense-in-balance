import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'cockpit_alert_slot.dart';
import 'cockpit_design.dart';
import 'cockpit_instruments.dart';
import 'protocol.dart';

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

/// Read-only companion for a browser or native phone; it never imitates Qwen.
class RepairMonitor extends StatefulWidget {
  const RepairMonitor({super.key, required this.url});
  final Uri url;
  @override
  State<RepairMonitor> createState() => _RepairMonitorState();
}

class _RepairMonitorState extends State<RepairMonitor> {
  WebSocketChannel? channel;
  StreamSubscription? subscription;
  Timer? retry, watch;
  Map<String, dynamic>? status;
  DateTime? lastAt;
  bool online = false;
  int generation = 0;
  int selectedView = 0;
  bool safetyActive = false;

  bool get frameFresh =>
      online &&
      lastAt != null &&
      DateTime.now().difference(lastAt!) < const Duration(seconds: 3);

  // An urgent event takes priority when it begins. Its changing heartbeat IDs
  // must not repeatedly pull the user out of the collaboration results view.
  void trackSafetyTransition() {
    final event = _parseCockpitEvent(status?['cockpit_event']);
    final urgent =
        _cockpitEventFresh(event, frameFresh) &&
        event!.decision.urgency == Urgency.safety;
    if (urgent && !safetyActive) selectedView = 0;
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
      final ch = WebSocketChannel.connect(widget.url);
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
                m['type'] == 'repair_status' &&
                m['schema'] == 1 &&
                m['task'] is Map) {
              if (mounted) {
                setState(() {
                  status = Map<String, dynamic>.from(m);
                  lastAt = DateTime.now();
                  online = true;
                  trackSafetyTransition();
                });
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

  void lost() {
    if (!mounted) return;
    setState(() {
      online = false;
      safetyActive = false;
    });
    retry?.cancel();
    retry = Timer(const Duration(seconds: 2), connect);
  }

  @override
  void dispose() {
    ++generation;
    retry?.cancel();
    watch?.cancel();
    unawaited(subscription?.cancel());
    _closeQuietly(channel);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fresh = frameFresh;
    final cockpitEvent = _parseCockpitEvent(status?['cockpit_event']);
    final cockpitFresh = _cockpitEventFresh(cockpitEvent, fresh);
    final task = status?['task'] as Map? ?? const {};
    final result = task['result'] as Map?;
    final phase = task['phase'];
    // Once freshness is lost, neither a previous receipt nor cached cabin state
    // is presented as current. The reconnecting shell stays visible on its own.
    final cabinState = !fresh || phase == 'indeterminate'
        ? null
        : status?['cabin_state'] is Map
        ? status!['cabin_state'] as Map
        : result?['state'] is Map
        ? result!['state'] as Map
        : null;
    final pending = fresh && task['pending'] is Map
        ? task['pending'] as Map
        : const {};
    final awaiting =
        fresh &&
        (phase == 'awaitingConfirmation' || phase == 'awaitingClarification');
    final headline = !fresh
        ? '等待重新連線'
        : switch (phase) {
            'parsing' => '正在理解需求',
            'awaitingConfirmation' => '需求已整理',
            'awaitingClarification' => '需要再說清楚',
            'executing' => '正在調整座艙',
            'completed' => '座艙調整完成',
            'cancelled' => '這次需求已取消',
            'failed' => '需求尚未完成',
            'indeterminate' => '執行結果待查證',
            _ => '等待新的需求',
          };
    final detail = !fresh
        ? '舊資料已隱藏；連線恢復後自動更新。'
        : switch (phase) {
            'parsing' => '其餘設定會保留，理解完成後再確認。',
            'awaitingConfirmation' => '等待乘客確認，座艙設定尚未改動。',
            'awaitingClarification' =>
              '${task['clarification'] ?? '請乘客在平板補充需求。'}',
            'executing' => '等待執行回報，請稍候。',
            'completed' => '執行回報已收到，兩個畫面保持同步。',
            'cancelled' => '待執行項目已清除，可提出新的需求。',
            'failed' || 'indeterminate' => '${task['error'] ?? '請在平板查看並確認。'}',
            _ => '乘客在平板提出需求，這裡只顯示狀態。',
          };
    final tone =
        !fresh ||
            phase == 'failed' ||
            phase == 'indeterminate' ||
            phase == 'awaitingClarification'
        ? CockpitStyle.amber
        : CockpitStyle.accent;
    final statusLabel = !fresh
        ? '連線中斷'
        : switch (phase) {
            'parsing' => '理解中',
            'awaitingConfirmation' => '待確認',
            'awaitingClarification' => '待補充',
            'executing' => '執行中',
            'completed' => '已完成',
            'cancelled' => '已取消',
            'failed' => '未執行',
            'indeterminate' => '待查證',
            _ => '準備就緒',
          };
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
            final statusPanel = _MonitorStatus(
              headline: headline,
              detail: detail,
              label: statusLabel,
              tone: tone,
              large: wide,
              pending: awaiting ? pending : const {},
              busy: fresh && (phase == 'parsing' || phase == 'executing'),
            );
            final viewSwitch = _MonitorViews(
              selected: selectedView,
              onSelected: (value) => setState(() => selectedView = value),
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
                          child: selectedView == 0
                              ? CockpitInstrumentPanel(
                                  event: cockpitEvent,
                                  fresh: cockpitFresh,
                                  height: panelHeight,
                                )
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
                                    ),
                                  ],
                                ),
                        );
                      },
                    ),
                  ),
                  SizedBox(height: shortLandscape ? 8 : 12),
                  const Text(
                    '行車訊號與車控均為模擬 · 第二屏只讀',
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
                    index == 0 ? '行車儀表' : '協作結果',
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
            '模擬訊號',
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

class _MonitorStatus extends StatelessWidget {
  const _MonitorStatus({
    required this.headline,
    required this.detail,
    required this.label,
    required this.tone,
    required this.large,
    required this.pending,
    required this.busy,
  });
  final String headline, detail, label;
  final Color tone;
  final bool large, busy;
  final Map pending;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: large ? 14 : 8, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: tone,
                fontSize: 11,
                letterSpacing: .8,
                fontVariations: const [ui.FontVariation('wght', 500)],
              ),
            ),
            const Spacer(),
            if (busy)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: tone),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          headline,
          style: TextStyle(
            color: CockpitStyle.text,
            fontSize: large ? 36 : 28,
            height: 1.3,
            fontVariations: const [ui.FontVariation('wght', 500)],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          detail,
          style: const TextStyle(
            color: CockpitStyle.muted,
            fontSize: 13,
            height: 1.7,
            fontVariations: [ui.FontVariation('wght', 400)],
          ),
        ),
        if (pending.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Divider(height: .5, thickness: .5, color: CockpitStyle.line),
          const SizedBox(height: 8),
          for (final entry in pending.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text(
                    _settingLabel('${entry.key}'),
                    style: const TextStyle(
                      color: CockpitStyle.text,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _changeLabel('${entry.value}'),
                    style: const TextStyle(
                      color: CockpitStyle.accent,
                      fontSize: 13,
                      fontVariations: [ui.FontVariation('wght', 500)],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
}

class _MonitorLevels extends StatelessWidget {
  const _MonitorLevels({required this.state, required this.wide});
  final Map? state;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final levels = [
      _MonitorLevel(
        label: '後座風量',
        icon: Icons.air_rounded,
        value: _readLevel(state, 'rearFan', 7),
        max: 7,
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
  });
  final String label;
  final IconData icon;
  final int? value;
  final int max;

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
            '/ $max',
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

String _settingLabel(String setting) => switch (setting) {
  'rearFan' => '後座風量',
  'mediaVolume' => '音樂音量',
  'navVolume' => '導航音量',
  _ => '待確認設定',
};

String _changeLabel(String change) => switch (change) {
  'decrease' => '降低一格',
  'increase' => '提高一格',
  'keep' => '保持不變',
  'remove' => '取消調整',
  _ => '待確認',
};
