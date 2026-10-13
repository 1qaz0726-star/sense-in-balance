import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cockpit_design.dart';
import 'repair_task.dart';

String cabinSettingLabel(String setting) => switch (setting) {
  'rearFan' => '後座風量',
  'mediaVolume' => '音樂音量',
  'navVolume' => '導航音量',
  _ => '待確認設定',
};

String requestedChangeLabel(String change) => switch (change) {
  'decrease' => '降低一格',
  'increase' => '提高一格',
  'keep' => '維持原值',
  'remove' => '取消此項',
  _ => '本次不調整',
};

/// Completed UI and speech both require the same actual simulated receipt.
Map? completedSimulatedCabinState(Map task) {
  final result = task['result'];
  if (task['phase'] != 'completed' ||
      result is! Map ||
      result['success'] != true ||
      result['simulated'] != true ||
      result['state'] is! Map) {
    return null;
  }
  final state = result['state'] as Map;
  for (final setting in CabinSetting.values) {
    final value = state[setting.name];
    final max = setting == CabinSetting.rearFan ? 7 : 10;
    if (value is! int || value < 0 || value > max) return null;
  }
  return state;
}

class DemoFaultNotice extends StatelessWidget {
  const DemoFaultNotice({super.key, required this.fault});
  final Map fault;

  @override
  Widget build(BuildContext context) {
    if (fault['source'] != 'manual_demo_injection') {
      return const SizedBox.shrink();
    }
    return Text(
      '${fault['label']}：${cabinSettingLabel('${fault['setting']}')}，'
      '${requestedChangeLabel('${fault['before']}')} → ${requestedChangeLabel('${fault['injected']}')}。'
      '來源為手動展示注入，不代表真實 Qwen 誤判。',
      style: cockpitText(12, color: CockpitStyle.amber, height: 1.7),
    );
  }
}

/// Manual edits produce candidates, never actuator calls or confirmations.
class PassengerCandidateEditor extends StatelessWidget {
  const PassengerCandidateEditor({
    super.key,
    required this.pending,
    required this.canRevise,
    required this.onPatch,
    this.changedSettings = const {},
    this.acknowledgedItems = const {},
  });
  final Map<CabinSetting, RequestedChange> pending;
  final bool canRevise;
  final void Function(CabinSetting, RequestedChange) onPatch;
  final Set<CabinSetting> changedSettings;
  final Map<CabinSetting, Map<String, dynamic>> acknowledgedItems;

  String _settingSummary(CabinSetting setting) {
    final change = pending[setting];
    if (change != null) return requestedChangeLabel(change.name);
    final item = acknowledgedItems[setting];
    if (item?['success'] == true) {
      final before = item?['before'];
      final after = item?['after'];
      return before is int && after is int ? '先前已完成（$before至$after）' : '先前已完成';
    }
    return '本次不調整';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '也可直接選擇一項；其餘需求保留',
        style: cockpitText(12, color: CockpitStyle.muted),
      ),
      const SizedBox(height: 8),
      for (final setting in CabinSetting.values)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: CockpitStyle.line, width: .5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cabinSettingLabel(setting.name),
                      style: cockpitText(15),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _settingSummary(setting),
                      style: cockpitText(
                        13,
                        color: changedSettings.contains(setting)
                            ? CockpitStyle.accent
                            : CockpitStyle.muted,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<RequestedChange>(
                key: ValueKey('passenger_edit_${setting.name}'),
                tooltip: '只修改${cabinSettingLabel(setting.name)}',
                enabled: canRevise,
                onSelected: (change) => onPatch(setting, change),
                itemBuilder: (_) => [
                  for (final change in [
                    RequestedChange.keep,
                    RequestedChange.remove,
                    RequestedChange.increase,
                    RequestedChange.decrease,
                  ])
                    PopupMenuItem(
                      value: change,
                      child: Text(requestedChangeLabel(change.name)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Text(
                    '改這一項',
                    style: cockpitText(
                      13,
                      color: canRevise
                          ? CockpitStyle.accent
                          : CockpitStyle.muted.withValues(alpha: .5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// A driver control surface. Authority always comes from a fresh server role;
/// pairing replies alone cannot grant controls or manufacture an execution ACK.
class DriverCollaborationPanel extends StatefulWidget {
  const DriverCollaborationPanel({
    super.key,
    required this.task,
    required this.collaboration,
    required this.fresh,
    required this.driver,
    required this.commandPending,
    required this.onPair,
    required this.onAction,
    this.changedSettings = const {},
    this.commandError,
    this.commandNotice,
    this.onSpeak,
    this.speechBusy = false,
    this.speechNotice,
  });
  final Map task;
  final Map collaboration;
  final bool fresh, driver, commandPending;
  final ValueChanged<String> onPair, onAction;
  final Set<String> changedSettings;
  final String? commandError, commandNotice;
  final VoidCallback? onSpeak;
  final bool speechBusy;
  final String? speechNotice;

  @override
  State<DriverCollaborationPanel> createState() =>
      _DriverCollaborationPanelState();
}

class _DriverCollaborationPanelState extends State<DriverCollaborationPanel> {
  final pairing = TextEditingController();
  final pairingFocus = FocusNode();

  @override
  void didUpdateWidget(covariant DriverCollaborationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.fresh || widget.driver) {
      pairingFocus.unfocus();
      pairing.clear();
    }
  }

  @override
  void dispose() {
    pairing.dispose();
    pairingFocus.dispose();
    super.dispose();
  }

  void _submitPairing(String code) {
    if (!widget.fresh ||
        widget.commandPending ||
        !RegExp(r'^\d{6}$').hasMatch(code)) {
      return;
    }
    pairingFocus.unfocus();
    widget.onPair(code);
    pairing.clear();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.fresh ? widget.task : const {};
    final phase = task['phase'];
    final pending = task['pending'] is Map ? task['pending'] as Map : const {};
    final active = const {
      'awaitingConfirmation',
      'awaitingClarification',
      'failed',
    }.contains(phase);
    final taskId = task['task_id'];
    final revision = task['revision'];
    final hasCurrentTask =
        taskId is String &&
        taskId.isNotEmpty &&
        revision is int &&
        revision >= 1;
    final driver = widget.fresh && widget.driver;
    final enabled = driver && !widget.commandPending;
    final authorized =
        driver &&
        widget.collaboration['passenger_authorized'] == true &&
        widget.collaboration['authorization_task_id'] == taskId;
    final expiry = widget.collaboration['authorization_expires_at'];
    final remaining = expiry is num
        ? ((expiry - DateTime.now().millisecondsSinceEpoch) / 1000)
              .ceil()
              .clamp(0, 120)
        : 0;
    final result = task['result'] is Map ? task['result'] as Map : const {};
    final items = result['items'] is Map ? result['items'] as Map : null;
    final hasPreviousSuccess =
        items?.values.any((item) => item is Map && item['success'] == true) ??
        false;
    final finalState = completedSimulatedCabinState(task);
    final completed = finalState != null;
    final demoFault = widget.fresh
        ? (widget.collaboration['demo_fault'] ??
              widget.collaboration['demo_fault_source'])
        : null;
    final headline = !widget.fresh
        ? '等待重新連線'
        : switch (phase) {
            'parsing' => '乘客正在整理需求',
            'awaitingConfirmation' => '請看需求摘要',
            'awaitingClarification' => '還有一項需要說清楚',
            'executing' => '等待模擬執行回報',
            'completed' => completed ? '模擬座艙已更新' : '執行回報待核對',
            'cancelled' => hasPreviousSuccess ? '已取消未執行需求' : '這次需求已取消',
            'failed' => '需求尚未完成',
            'indeterminate' => '執行結果待查證',
            _ => '駕駛看摘要，乘客改細節',
          };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          driver
              ? '已配對駕駛屏'
              : widget.fresh
              ? '觀察模式 · 尚未配對'
              : '連線已中斷',
          style: cockpitText(
            11,
            color: driver ? CockpitStyle.accent : CockpitStyle.amber,
          ),
        ),
        const SizedBox(height: 12),
        Text(headline, style: cockpitText(27, weight: FontWeight.w400)),
        const SizedBox(height: 10),
        Text(
          !widget.fresh
              ? '舊摘要與數值已隱藏。恢復連線後需重新配對。'
              : phase == 'completed'
              ? completed
                    ? '已收到模擬執行回報；未連接真實車輛。'
                    : '未取得完整的模擬執行回報，暫不顯示完成。'
              : phase == 'cancelled'
              ? hasPreviousSuccess
                    ? '已取消未執行需求；已完成設定不會還原。'
                    : '這次需求尚未執行，已取消。'
              : phase == 'executing'
              ? '確認已送出；收到回報前不會顯示完成，也不能再送一次。'
              : phase == 'indeterminate'
              ? '${task['error'] ?? '回報未知；先查證，不可重送。'}'
              : '候選不會直接執行。你可授權乘客只改細節，最後由你確認。',
          style: cockpitText(13, color: CockpitStyle.muted, height: 1.7),
        ),
        if (items != null &&
            (phase == 'failed' ||
                phase == 'awaitingConfirmation' ||
                (phase == 'cancelled' && hasPreviousSuccess))) ...[
          const SizedBox(height: 16),
          Text(
            phase == 'failed'
                ? '部分執行回報 · 未完成項仍待處理'
                : phase == 'cancelled'
                ? '先前已完成設定 · 不會還原'
                : '先前執行回報 · 本次僅確認待執行項',
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
          for (final setting in CabinSetting.values)
            if (items[setting.name] is Map &&
                (phase != 'cancelled' ||
                    (items[setting.name] as Map)['success'] == true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        cabinSettingLabel(setting.name),
                        style: cockpitText(13),
                      ),
                    ),
                    Text(
                      '${(items[setting.name] as Map)['before']} → ${(items[setting.name] as Map)['after']} · ${(items[setting.name] as Map)['success'] == true ? '已完成' : '未完成'}',
                      style: cockpitText(
                        13,
                        color: (items[setting.name] as Map)['success'] == true
                            ? CockpitStyle.accent
                            : CockpitStyle.amber,
                      ),
                    ),
                  ],
                ),
              ),
        ],
        if (widget.fresh && (active || phase == 'parsing')) ...[
          const SizedBox(height: 18),
          if (widget.changedSettings.isNotEmpty &&
              revision is int &&
              revision > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '這次只改：${widget.changedSettings.map(cabinSettingLabel).join('、')}；其餘保留',
                style: cockpitText(13, color: CockpitStyle.accent),
              ),
            ),
          for (final setting in CabinSetting.values)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: CockpitStyle.line, width: .5),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      cabinSettingLabel(setting.name),
                      style: cockpitText(14),
                    ),
                  ),
                  Text(
                    requestedChangeLabel('${pending[setting.name] ?? ''}'),
                    style: cockpitText(
                      14,
                      color: widget.changedSettings.contains(setting.name)
                          ? CockpitStyle.accent
                          : CockpitStyle.muted,
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (widget.fresh && task['clarification'] is String) ...[
          const SizedBox(height: 12),
          Text(
            '${task['clarification']}',
            style: cockpitText(14, color: CockpitStyle.amber),
          ),
        ],
        if (widget.fresh && phase == 'failed' && task['error'] is String) ...[
          const SizedBox(height: 10),
          Text(
            '${task['error']}',
            style: cockpitText(13, color: CockpitStyle.amber),
          ),
        ],
        if (completed) ...[
          const SizedBox(height: 16),
          _CompletedRepairValues(
            state: finalState,
            items: items,
            requested: pending,
          ),
          if (widget.onSpeak != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.speechBusy ? null : widget.onSpeak,
                icon: const Icon(Icons.volume_up_outlined, size: 17),
                label: Text(widget.speechBusy ? '正在播報…' : '播報結果'),
              ),
            ),
          ],
          if (widget.speechNotice != null)
            Text(
              widget.speechNotice!,
              style: cockpitText(12, color: CockpitStyle.muted),
            ),
        ],
        if (demoFault is Map) ...[
          const SizedBox(height: 12),
          DemoFaultNotice(fault: demoFault),
        ],
        const SizedBox(height: 20),
        if (!driver) ...[
          Text(
            '在乘客平板打開「連接駕駛屏」，輸入六位配對碼。',
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: pairing,
            builder: (_, value, _) => Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 170,
                  child: TextField(
                    key: const ValueKey('driver_pairing_code'),
                    controller: pairing,
                    focusNode: pairingFocus,
                    enabled: widget.fresh && !widget.commandPending,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onSubmitted: _submitPairing,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: cockpitText(20, letterSpacing: 4),
                    decoration: const InputDecoration(
                      hintText: '六位碼',
                      counterText: '',
                    ),
                  ),
                ),
                FilledButton(
                  key: const ValueKey('driver_pair'),
                  onPressed:
                      widget.fresh &&
                          !widget.commandPending &&
                          RegExp(r'^\d{6}$').hasMatch(value.text)
                      ? () => _submitPairing(value.text)
                      : null,
                  child: Text(widget.commandPending ? '配對中…' : '配對駕駛屏'),
                ),
              ],
            ),
          ),
        ] else if (hasCurrentTask && (active || phase == 'parsing')) ...[
          Text(
            authorized && remaining > 0
                ? '乘客已獲本次授權 · 剩餘 $remaining 秒'
                : '乘客尚未獲授權；候選摘要不會自行執行。',
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              if (active)
                OutlinedButton(
                  key: const ValueKey('driver_grant'),
                  onPressed: enabled && hasCurrentTask && active
                      ? () => widget.onAction('grant')
                      : null,
                  child: const Text('授權乘客協助 120 秒'),
                ),
              if (authorized)
                TextButton(
                  key: const ValueKey('driver_revoke'),
                  onPressed: enabled && hasCurrentTask
                      ? () => widget.onAction('revoke')
                      : null,
                  child: const Text('收回授權'),
                ),
              if (active)
                FilledButton(
                  key: const ValueKey('driver_confirm'),
                  onPressed:
                      enabled &&
                          hasCurrentTask &&
                          phase == 'awaitingConfirmation'
                      ? () => widget.onAction('confirm')
                      : null,
                  child: const Text('確認套用（車控模擬）'),
                ),
              TextButton(
                key: const ValueKey('driver_cancel'),
                onPressed:
                    enabled && hasCurrentTask && (active || phase == 'parsing')
                    ? () => widget.onAction('cancel')
                    : null,
                child: const Text('取消這次需求'),
              ),
            ],
          ),
        ] else ...[
          Text(
            phase == 'completed' && !completed
                ? '請先核對執行回報，暫不重送。'
                : phase == 'completed' || phase == 'cancelled'
                ? '本次已結束，可由乘客提出新需求。'
                : phase == 'executing'
                ? '本次已確認，等待執行回報。'
                : phase == 'indeterminate'
                ? '結果未確認，不可再次套用。'
                : '等待乘客提出需求。',
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
        ],
        if (widget.commandError != null) ...[
          const SizedBox(height: 12),
          Text(
            widget.commandError!,
            style: cockpitText(13, color: CockpitStyle.amber),
          ),
        ] else if (widget.commandNotice != null) ...[
          const SizedBox(height: 12),
          Text(
            widget.commandNotice!,
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
        ],
      ],
    );
  }
}

class _CompletedRepairValues extends StatelessWidget {
  const _CompletedRepairValues({
    required this.state,
    required this.items,
    required this.requested,
  });
  final Map state;
  final Map? items;
  final Map requested;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('最終設定 · 模擬執行回報', style: cockpitText(12, color: CockpitStyle.muted)),
      for (final setting in CabinSetting.values)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: CockpitStyle.line, width: .5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cabinSettingLabel(setting.name),
                      style: cockpitText(14),
                    ),
                    if (items != null ||
                        requested.containsKey(setting.name)) ...[
                      const SizedBox(height: 3),
                      Text(
                        items?[setting.name] is Map
                            ? '${(items![setting.name] as Map)['before']} → ${(items![setting.name] as Map)['after']} · ${(items![setting.name] as Map)['success'] == true ? '已回報' : '未完成'}'
                            : requested.containsKey(setting.name)
                            ? '未提供逐項回報'
                            : '未列入這次調整',
                        style: cockpitText(11, color: CockpitStyle.muted),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                '${state[setting.name]}',
                key: ValueKey('driver_final_${setting.name}'),
                style: cockpitText(28, weight: FontWeight.w400),
              ),
              Text(
                ' / ${setting == CabinSetting.rearFan ? 7 : 10}',
                style: cockpitText(11, color: CockpitStyle.muted),
              ),
            ],
          ),
        ),
    ],
  );
}
