import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cockpit_design.dart';
import 'cabin_coordination_widgets.dart';
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

/// 駕駛確認頁的一句話摘要：行車中只讀這一句，明細要按「看明細」才展開。
String driverOneLineSummary(Map pending, Map unsupported) {
  const short = {'rearFan': '後座風', 'mediaVolume': '音樂', 'navVolume': '導航'};
  final parts = <String>[];
  for (final setting in CabinSetting.values) {
    final name = setting.name;
    if (!pending.containsKey(name)) continue;
    final change = '${pending[name]}';
    parts.add(
      unsupported.containsKey(name)
          ? '${short[name]}此車不支援'
          : '${short[name]}${switch (change) {
              'decrease' => '小一格',
              'increase' => '大一格',
              'keep' => '不變',
              'remove' => '取消',
              _ => '待確認',
            }}',
    );
  }
  return parts.isEmpty ? '沒有待確認的調整' : parts.join('，');
}

/// Completed UI and speech both require the same actual simulated receipt.
Map? completedSimulatedCabinState(Map task, {Map? cabinContext}) {
  final result = task['result'];
  if (task['phase'] != 'completed' ||
      result is! Map ||
      result['success'] != true ||
      result['simulated'] != true ||
      result['state'] is! Map) {
    return null;
  }
  final state = result['state'] as Map;
  if (cabinContext != null) {
    final execution = result['execution_context'];
    if (execution is! Map ||
        execution.length != 3 ||
        execution['cabin_session_id'] != cabinContext['cabin_session_id'] ||
        execution['profile_id'] != cabinContext['profile_id'] ||
        execution['profile_revision'] != cabinContext['profile_revision']) {
      return null;
    }
    final items = result['items'];
    final pending = task['pending'];
    if (items is! Map ||
        pending is! Map ||
        pending.isEmpty ||
        items.length != pending.length) {
      return null;
    }
    for (final name in pending.keys) {
      if (!cabinSettingReadable(cabinContext, '$name') ||
          items[name] is! Map ||
          (items[name] as Map)['success'] != true ||
          (items[name] as Map)['before'] is! int ||
          (items[name] as Map)['after'] != state[name]) {
        return null;
      }
    }
  }
  for (final setting in CabinSetting.values) {
    if (!cabinSettingReadable(cabinContext, setting.name)) continue;
    final value = state[setting.name];
    final max = setting == CabinSetting.rearFan ? 7 : 10;
    if (value is! int || value < 0 || value > max) return null;
  }
  return {
    for (final setting in CabinSetting.values)
      setting.name: cabinSettingReadable(cabinContext, setting.name)
          ? state[setting.name]
          : null,
  };
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
    this.unsupported = const {},
    this.removedSettings = const {},
  });
  final Map<CabinSetting, RequestedChange> pending;
  final bool canRevise;
  final void Function(CabinSetting, RequestedChange) onPatch;
  final Set<CabinSetting> changedSettings;
  final Map<CabinSetting, Map<String, dynamic>> acknowledgedItems;
  final Map unsupported;
  final Set<CabinSetting> removedSettings;

  String _settingSummary(CabinSetting setting) {
    final change = pending[setting];
    if (removedSettings.contains(setting) && change == null) {
      return '待辦已取消，未送出';
    }
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
                    if (pending.containsKey(setting) &&
                        unsupported.containsKey(setting.name)) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${unsupported[setting.name]}',
                        style: cockpitText(12, color: CockpitStyle.amber),
                      ),
                    ],
                  ],
                ),
              ),
              if (pending.containsKey(setting) &&
                  unsupported.containsKey(setting.name))
                TextButton(
                  key: ValueKey('passenger_remove_${setting.name}'),
                  onPressed: canRevise
                      ? () => onPatch(setting, RequestedChange.remove)
                      : null,
                  child: const Text('取消此項'),
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
    this.cabinContext,
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
  final Map? cabinContext;

  @override
  State<DriverCollaborationPanel> createState() =>
      _DriverCollaborationPanelState();
}

class _DriverCollaborationPanelState extends State<DriverCollaborationPanel> {
  final pairing = TextEditingController();
  final pairingFocus = FocusNode();
  bool showDetails = false;
  bool showMore = false;

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
    final finalState = completedSimulatedCabinState(
      task,
      cabinContext: widget.cabinContext,
    );
    final completed = finalState != null;
    final blocked = cabinAttentionBlocked(widget.cabinContext);
    final resume = cabinRequiresResume(widget.cabinContext);
    final unsupported = cabinUnsupported(widget.cabinContext);
    final contextInfo = widget.cabinContext;
    final contextReady =
        contextInfo == null ||
        contextInfo[resume ? 'can_resume_confirm' : 'can_confirm'] == true;
    final demoFault = widget.fresh
        ? (widget.collaboration['demo_fault'] ??
              widget.collaboration['demo_fault_source'])
        : null;
    final headline = !widget.fresh
        ? '等待重新連線'
        : blocked && phase != 'indeterminate' && phase != 'executing'
        ? cabinAttentionHeadline(widget.cabinContext)
        : active && unsupported.isNotEmpty
        ? '有一項此車不支援'
        : resume && phase == 'awaitingConfirmation'
        ? '確認最新需求'
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
              ? '已配對駕駛屏${widget.cabinContext?['profile'] is Map ? ' · ${(widget.cabinContext!['profile'] as Map)['label']}' : ''}'
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
              : blocked
              ? '乘客需求已保留，暫不需要處理。'
              : unsupported.isNotEmpty && active
              ? '請由乘客取消受限待辦，再確認其餘設定；不會自動改其他設備。'
              : resume
              ? '優先事件已解除；請核對最新摘要，確認後才套用。'
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
        if (widget.fresh && !blocked && (active || phase == 'parsing')) ...[
          const SizedBox(height: 18),
          if (pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                driverOneLineSummary(pending, unsupported),
                key: const ValueKey('driver_one_line'),
                style: cockpitText(22, height: 1.4),
              ),
            ),
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
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('driver_details_toggle'),
              onPressed: () => setState(() => showDetails = !showDetails),
              child: Text(showDetails ? '收起明細' : '看明細'),
            ),
          ),
          if (showDetails)
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
                      unsupported.containsKey(setting.name)
                          ? '此車受限 · 未送出'
                          : requestedChangeLabel(
                              '${pending[setting.name] ?? ''}',
                            ),
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
        if (widget.fresh && !blocked && task['clarification'] is String) ...[
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
        if (completed && !blocked) ...[
          const SizedBox(height: 16),
          _CompletedRepairValues(
            state: finalState,
            items: items,
            requested: pending,
            cabinContext: widget.cabinContext,
          ),
          if (widget.onSpeak != null && !blocked) ...[
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
          // 主操作只有一個：整排寬的確認鍵。授權留在下一排；收回授權、取消收進「更多」。
          if (active && !blocked)
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                key: const ValueKey('driver_confirm'),
                onPressed:
                    enabled &&
                        hasCurrentTask &&
                        phase == 'awaitingConfirmation' &&
                        contextReady &&
                        unsupported.isEmpty
                    ? () =>
                          widget.onAction(resume ? 'resume_confirm' : 'confirm')
                    : null,
                child: Text(
                  widget.cabinContext == null
                      ? '確認套用（車控模擬）'
                      : unsupported.isNotEmpty
                      ? '先處理受限項目'
                      : resume
                      ? '繼續並確認最新 ${pending.length} 項'
                      : '確認這次調整',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            authorized && remaining > 0
                ? '乘客可修改 · 剩 $remaining 秒'
                : '按確認前不會執行。',
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (active && !blocked)
                OutlinedButton(
                  key: const ValueKey('driver_grant'),
                  onPressed:
                      enabled &&
                          hasCurrentTask &&
                          active &&
                          (widget.cabinContext == null ||
                              widget.cabinContext?['can_grant'] == true)
                      ? () => widget.onAction('grant')
                      : null,
                  child: const Text('讓乘客修改（120 秒）'),
                ),
              TextButton(
                key: const ValueKey('driver_more'),
                onPressed: () => setState(() => showMore = !showMore),
                child: Text(showMore ? '收起' : '更多'),
              ),
              if (showMore && authorized)
                TextButton(
                  key: const ValueKey('driver_revoke'),
                  onPressed: enabled && hasCurrentTask
                      ? () => widget.onAction('revoke')
                      : null,
                  child: const Text('收回授權'),
                ),
              if (showMore)
                TextButton(
                  key: const ValueKey('driver_cancel'),
                  onPressed:
                      enabled &&
                          hasCurrentTask &&
                          (active || phase == 'parsing')
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
    this.cabinContext,
  });
  final Map state;
  final Map? items;
  final Map requested;
  final Map? cabinContext;

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
                        !cabinSettingReadable(cabinContext, setting.name)
                            ? '此模擬座艙未提供介面；未送出'
                            : items?[setting.name] is Map
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
                state[setting.name]?.toString() ?? '—',
                key: ValueKey('driver_final_${setting.name}'),
                style: cockpitText(28, weight: FontWeight.w400),
              ),
              Text(
                cabinSettingReadable(cabinContext, setting.name)
                    ? ' / ${setting == CabinSetting.rearFan ? 7 : 10}'
                    : ' / 不提供',
                style: cockpitText(11, color: CockpitStyle.muted),
              ),
            ],
          ),
        ),
    ],
  );
}
