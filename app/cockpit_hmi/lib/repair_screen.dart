import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cockpit_design.dart';
import 'cockpit_alert_slot.dart';
import 'cockpit_instruments.dart';
import 'hub.dart' as original;
import 'protocol.dart';
import 'repair_hub.dart';
import 'repair_parser.dart';
import 'repair_remote_model.dart';
import 'repair_task.dart';
import 'setup.dart';
import 'slm.dart';

class RepairScreen extends StatefulWidget {
  const RepairScreen({super.key});
  @override
  State<RepairScreen> createState() => _RepairScreenState();
}

class _RepairScreenState extends State<RepairScreen> {
  final input = TextEditingController();
  late final RepairController controller;
  late final RepairHub hub;
  late final RemoteRepairModel? remoteModel;
  final actuator = MockCabinActuator();
  final cockpit = original.Hub.I;
  bool ownsCockpit = false;
  bool showInstruments = true;
  bool lastFresh = false;
  Timer? cockpitWatch;
  String address = '正在準備另一台平板的連線…';

  bool get modelReady => remoteModel?.ready ?? Slm.I.ready;
  String get modelStatus => remoteModel?.status ?? modelStatusText(Slm.I);

  bool get cockpitFresh {
    final event = cockpit.last;
    if (!cockpit.running ||
        event == null ||
        event.availability != Avail.ok ||
        !event.ts.isFinite) {
      return false;
    }
    final age = DateTime.now().millisecondsSinceEpoch / 1000 - event.ts;
    return age >= 0 && age <= 3;
  }

  @override
  void initState() {
    super.initState();
    remoteModel = kRepairModelUrl.isEmpty
        ? null
        : RemoteRepairModel(Uri.parse(kRepairModelUrl));
    ownsCockpit = !cockpit.running;
    if (ownsCockpit) {
      cockpit.setScene(Scene.normal);
      cockpit.clearDemoEvents();
      unawaited(cockpit.start(network: false));
    }
    cockpitWatch = Timer.periodic(const Duration(seconds: 1), (_) {
      final fresh = cockpitFresh;
      if (mounted && fresh != lastFresh) setState(() => lastFresh = fresh);
    });
    controller = RepairController(
      parseTimeout: Duration(seconds: remoteModel == null ? 15 : 30),
      parser: RepairParser(
        (system, prompt) {
          if (!modelReady) return Future.error(StateError('請先準備模型'));
          return remoteModel?.generate(system, prompt) ??
              Slm.I.generate(system, prompt);
        },
        onTrace: const bool.fromEnvironment('REPAIR_EVAL_LOG')
            ? (trace) => debugPrint(
                'REPAIR_EVAL ${jsonEncode({...trace, 'backend': remoteModel == null ? Slm.I.backend : 'PC GGUF Q8'})}',
              )
            : null,
      ).call,
      actuator: actuator.call,
    );
    hub = RepairHub(
      controller,
      modelStatus: () => modelStatus,
      cabinState: () => {
        for (final entry in actuator.state.entries) entry.key.name: entry.value,
      },
      cockpitEvent: () => cockpit.last?.toJson(),
      cockpitSignals: cockpit,
      asset: (path) async {
        try {
          final data = await rootBundle.load('assets/repair_web/$path');
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } catch (_) {
          return null;
        }
      },
    );
    unawaited(remoteModel?.boot() ?? Slm.I.boot());
    hub
        .start()
        .then((_) {
          if (mounted) {
            setState(
              () => address = remoteModel != null
                  ? '電腦雙裝置實測：平板操作，手機同步顯示。'
                  : hub.addresses.isEmpty
                  ? '請連上本地 Wi-Fi 後重開此頁。'
                  : '另一台平板開瀏覽器：${hub.addresses.map((ip) => 'http://$ip:${RepairHub.port}').join(' 或 ')}',
            );
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => address = '雙屏主機未啟動：$e');
        });
  }

  @override
  void dispose() {
    cockpitWatch?.cancel();
    unawaited(hub.stop());
    if (ownsCockpit) unawaited(cockpit.stop());
    controller.cancel();
    controller.dispose();
    input.dispose();
    remoteModel?.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final current = controller.snapshot.phase;
    if (current == RepairPhase.parsing ||
        current == RepairPhase.executing ||
        current == RepairPhase.indeterminate) {
      return;
    }
    final value = input.text.trim();
    if (value.isEmpty) return;
    FocusScope.of(context).unfocus();
    final phase = controller.snapshot.phase;
    final active =
        phase == RepairPhase.awaitingConfirmation ||
        phase == RepairPhase.awaitingClarification ||
        phase == RepairPhase.failed;
    final accepted = active
        ? await controller.revise(value)
        : await controller.newTask(value);
    if (accepted && mounted) input.clear();
  }

  void showConnection() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CockpitStyle.panel,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '本地 AI 與雙屏連線',
                style: cockpitText(22, weight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Text(
                modelStatus,
                style: cockpitText(15, color: CockpitStyle.muted),
              ),
              const SizedBox(height: 12),
              SelectableText(
                address,
                style: cockpitText(15, color: CockpitStyle.muted),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: Icon(
                  remoteModel != null
                      ? Icons.refresh_rounded
                      : Icons.settings_outlined,
                ),
                label: Text(remoteModel != null ? '重新連接模型' : '開啟模型設定'),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  if (remoteModel != null) {
                    unawaited(remoteModel!.boot());
                  } else {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ModelSetupPage()),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CockpitStyle.theme,
    child: Scaffold(
      backgroundColor: CockpitStyle.bg,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            controller,
            remoteModel ?? Slm.I,
            cockpit,
          ]),
          builder: (context, _) {
            final task = controller.snapshot;
            return Column(
              children: [
                _header(),
                CockpitAlertSlot(event: cockpit.last, fresh: cockpitFresh),
                if (MediaQuery.sizeOf(context).width < 920)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _viewPicker(),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      if (showInstruments) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                          child: CockpitInstrumentPanel(
                            event: cockpit.last,
                            fresh: cockpitFresh,
                            height: (box.maxHeight - 20)
                                .clamp(120, 1000)
                                .toDouble(),
                          ),
                        );
                      }
                      final wide = box.maxWidth >= 900;
                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 44 : 24,
                          20,
                          wide ? 44 : 24,
                          18,
                        ),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(flex: 4, child: _overview(task)),
                                  Container(
                                    width: 1,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 36,
                                    ),
                                    color: CockpitStyle.line,
                                  ),
                                  Expanded(flex: 6, child: _taskPanel(task)),
                                ],
                              )
                            : _taskPanel(task),
                      );
                    },
                  ),
                ),
                if (showInstruments) _simulationStrip() else _levels(task),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '平板操作 · 第二屏同步',
                          style: cockpitText(11, color: CockpitStyle.muted),
                        ),
                      ),
                      Text(
                        '展示模擬 · 未連接真實車輛',
                        style: cockpitText(11, color: CockpitStyle.muted),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _header() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: CockpitStyle.line, width: .5)),
    ),
    child: Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '感知有度',
              style: cockpitText(21, weight: FontWeight.w500, letterSpacing: 2),
            ),
            Text(
              'SENSE IN BALANCE',
              style: cockpitText(
                9,
                color: CockpitStyle.muted,
                letterSpacing: 2.4,
              ),
            ),
          ],
        ),
        if (MediaQuery.sizeOf(context).width >= 920) ...[
          const SizedBox(width: 56),
          _viewPicker(),
        ],
        const Spacer(),
        if (MediaQuery.sizeOf(context).width >= 620) ...[
          TextButton(onPressed: _showSimulation, child: const Text('展示情境')),
          const SizedBox(width: 20),
          Text(
            modelReady ? '本地 AI 就緒' : 'AI 準備中',
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
          const SizedBox(width: 24),
        ],
        const CockpitClock(),
        const SizedBox(width: 16),
        IconButton(
          tooltip: '本地 AI 與雙屏連線',
          onPressed: showConnection,
          icon: const Icon(Icons.tune, size: 19, color: CockpitStyle.muted),
        ),
      ],
    ),
  );

  Widget _viewPicker() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final instruments in [true, false])
        InkWell(
          onTap: () => setState(() => showInstruments = instruments),
          child: Container(
            constraints: const BoxConstraints(minWidth: 128, minHeight: 48),
            alignment: Alignment.center,
            margin: const EdgeInsets.only(right: 22),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: showInstruments == instruments
                      ? CockpitStyle.accent
                      : Colors.transparent,
                  width: 1.5,
                ),
              ),
            ),
            child: Text(
              instruments ? '行車儀表' : '座艙主控',
              style: cockpitText(
                16,
                color: showInstruments == instruments
                    ? CockpitStyle.text
                    : CockpitStyle.muted,
              ),
            ),
          ),
        ),
    ],
  );

  void _setScene(Scene scene) {
    cockpit.setScene(scene);
    cockpit.clearDemoEvents();
  }

  void _showSimulation() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CockpitStyle.bg,
      shape: const RoundedRectangleBorder(),
      builder: (_) => SafeArea(
        child: AnimatedBuilder(
          animation: cockpit,
          builder: (_, _) => _simulationStrip(),
        ),
      ),
    );
  }

  Widget _simulationStrip() => Container(
    padding: const EdgeInsets.fromLTRB(28, 14, 28, 12),
    decoration: const BoxDecoration(
      color: CockpitStyle.panel,
      border: Border(top: BorderSide(color: CockpitStyle.line, width: .5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              '展示情境',
              style: cockpitText(
                11,
                color: CockpitStyle.muted,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                'CO₂ ${cockpit.co2.round()} ppm · ${cockpit.recirc}循環',
                textAlign: TextAlign.right,
                style: cockpitText(11, color: CockpitStyle.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _sceneControl(
                '正常行車',
                Icons.directions_car_outlined,
                () => _setScene(Scene.normal),
              ),
              _sceneControl(
                '模擬停車',
                Icons.local_parking,
                () => _setScene(Scene.parked),
              ),
              _sceneControl(
                '左後方自行車',
                Icons.pedal_bike,
                () => cockpit.injectBlindSpot(
                  side: 'left',
                  object: '自行車',
                  seconds: 10,
                ),
              ),
              _sceneControl(
                '右後方機車',
                Icons.two_wheeler,
                () => cockpit.injectBlindSpot(
                  side: 'right',
                  object: '機車',
                  seconds: 10,
                ),
              ),
              _sceneControl(
                'CO₂ 上升與換氣',
                Icons.air,
                () => _setScene(Scene.co2Rising),
              ),
              _sceneControl(
                '左後方汽車',
                Icons.directions_car_outlined,
                () => cockpit.injectBlindSpot(
                  side: 'left',
                  object: '汽車',
                  seconds: 10,
                ),
              ),
              _sceneControl(
                '右後方汽車',
                Icons.directions_car_outlined,
                () => cockpit.injectBlindSpot(
                  side: 'right',
                  object: '汽車',
                  seconds: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _sceneControl(String label, IconData icon, VoidCallback action) =>
      Padding(
        padding: const EdgeInsets.only(right: 22),
        child: TextButton.icon(
          onPressed: action,
          style: TextButton.styleFrom(
            foregroundColor: CockpitStyle.text,
            minimumSize: const Size(130, 46),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            shape: const RoundedRectangleBorder(),
            textStyle: cockpitText(15),
          ),
          icon: Icon(icon, size: 18, color: CockpitStyle.muted),
          label: Text(label),
        ),
      );

  Widget _overview(RepairSnapshot task) => LayoutBuilder(
    builder: (context, box) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '座艙空間',
              style: cockpitText(
                12,
                color: CockpitStyle.muted,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            Text(
              cockpitFresh
                  ? '${cockpit.last?.vehicle?['gear'] ?? '—'}  ·  ${cockpit.last?.speed?.round() ?? '—'} km/h'
                  : '行車訊號未更新',
              style: cockpitText(12, color: CockpitStyle.muted),
            ),
          ],
        ),
        Expanded(
          child: Center(
            child: CabinVehicleGraphic(
              height: (box.maxHeight - 72).clamp(80, 430).toDouble(),
              highlightRear: task.pending.containsKey(CabinSetting.rearFan),
            ),
          ),
        ),
        Center(
          child: Text(
            task.pending.containsKey(CabinSetting.rearFan)
                ? '後座風量 · 待確認'
                : '後座舒適',
            style: cockpitText(
              14,
              color: CockpitStyle.accent,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    ),
  );

  Widget _taskPanel(RepairSnapshot task) {
    final busy =
        task.phase == RepairPhase.parsing ||
        task.phase == RepairPhase.executing ||
        task.phase == RepairPhase.indeterminate;
    final revising =
        task.phase == RepairPhase.awaitingConfirmation ||
        task.phase == RepairPhase.awaitingClarification ||
        task.phase == RepairPhase.failed;
    final canCancel = task.phase == RepairPhase.parsing || revising;
    final canConfirm = task.phase == RepairPhase.awaitingConfirmation;
    final tone = task.phase == RepairPhase.completed
        ? CockpitStyle.accent
        : CockpitStyle.amber;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '座艙需求',
                  style: cockpitText(
                    12,
                    color: CockpitStyle.muted,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  revising ? '只說要修改的部分' : '改一件事，其餘記得住',
                  style: cockpitText(27, weight: FontWeight.w400),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: input,
                  minLines: 2,
                  maxLines: 2,
                  maxLength: 500,
                  enabled: !busy,
                  style: cockpitText(19),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: revising
                        ? '例如：風量先不用改，其餘照剛剛。'
                        : '後座風小一點，音樂也小一點，\n導航提示不要變。',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () => input.text = revising
                                    ? '風量先不用改，其餘照剛剛。'
                                    : '後座風小一點，音樂也小一點，導航提示不要變。',
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            textStyle: cockpitText(12),
                          ),
                          child: Text(revising ? '帶入「只取消風量」' : '帶入示範需求'),
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: busy || !modelReady ? null : submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(145, 46),
                        textStyle: cockpitText(15, weight: FontWeight.w500),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            )
                          : const Icon(Icons.arrow_forward, size: 18),
                      label: Text(
                        task.phase == RepairPhase.indeterminate
                            ? '結果待查證'
                            : busy
                            ? '處理中'
                            : revising
                            ? '更新需求'
                            : '整理需求',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  _phaseText(task.phase),
                  style: cockpitText(
                    16,
                    color: task.phase == RepairPhase.idle
                        ? CockpitStyle.muted
                        : tone,
                    weight: FontWeight.w500,
                  ),
                ),
                if (task.phase == RepairPhase.idle ||
                    task.phase == RepairPhase.cancelled) ...[
                  const SizedBox(height: 8),
                  Text(
                    '一次說出多個需求，也能只改其中一項。\n確認後才套用模擬設定。',
                    style: cockpitText(
                      13,
                      color: CockpitStyle.muted,
                      height: 1.8,
                    ),
                  ),
                ],
                if (task.phase == RepairPhase.parsing) ...[
                  const SizedBox(height: 8),
                  Text(
                    '座艙設定尚未改動。',
                    style: cockpitText(13, color: CockpitStyle.muted),
                  ),
                ],
                if (task.phase != RepairPhase.indeterminate)
                  for (final entry in task.pending.entries)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: CockpitStyle.line,
                            width: .5,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _settingIcon(entry.key),
                            size: 18,
                            color: CockpitStyle.muted,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _settingName(entry.key),
                              style: cockpitText(16),
                            ),
                          ),
                          Text(
                            _changeName(entry.value),
                            style: cockpitText(
                              16,
                              color: entry.value == RequestedChange.keep
                                  ? CockpitStyle.muted
                                  : CockpitStyle.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                if (task.clarification != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    task.clarification!,
                    style: cockpitText(16, color: CockpitStyle.amber),
                  ),
                ],
                if (task.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    task.error!,
                    style: cockpitText(14, color: CockpitStyle.amber),
                  ),
                ],
                if (task.phase == RepairPhase.completed) ...[
                  const SizedBox(height: 10),
                  Text(
                    '模擬設定已更新，第二屏同步顯示結果。',
                    style: cockpitText(13, color: CockpitStyle.muted),
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        if (canCancel)
          Container(
            padding: const EdgeInsets.only(top: 12),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: CockpitStyle.line, width: .5),
              ),
            ),
            child: Row(
              children: [
                if (canConfirm)
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          controller.confirm(task.taskId!, task.revision),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(100, 48),
                        textStyle: cockpitText(16, weight: FontWeight.w500),
                      ),
                      child: const Text('確認套用（模擬）'),
                    ),
                  )
                else
                  Expanded(
                    child: Text(
                      '尚未更動座艙',
                      style: cockpitText(13, color: CockpitStyle.muted),
                    ),
                  ),
                const SizedBox(width: 18),
                TextButton(
                  onPressed: () => controller.cancel(),
                  child: const Text('取消需求'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _levels(RepairSnapshot task) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 14),
    decoration: const BoxDecoration(
      color: CockpitStyle.panel,
      border: Border(top: BorderSide(color: CockpitStyle.line, width: .5)),
    ),
    child: Row(
      children: [
        for (final setting in CabinSetting.values) ...[
          if (setting != CabinSetting.values.first)
            Container(
              width: 1,
              height: 42,
              margin: const EdgeInsets.symmetric(horizontal: 30),
              color: CockpitStyle.line,
            ),
          Expanded(
            child: _LevelTile(
              setting: setting,
              value: task.phase == RepairPhase.indeterminate
                  ? null
                  : actuator.state[setting],
              pending: task.phase == RepairPhase.awaitingConfirmation
                  ? task.pending[setting]
                  : null,
            ),
          ),
        ],
      ],
    ),
  );
}

class _LevelTile extends StatelessWidget {
  const _LevelTile({required this.setting, required this.value, this.pending});
  final CabinSetting setting;
  final int? value;
  final RequestedChange? pending;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Icon(_settingIcon(setting), size: 18, color: CockpitStyle.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _settingName(setting),
              style: cockpitText(13, color: CockpitStyle.muted),
            ),
          ),
          Text(
            value?.toString() ?? '—',
            style: cockpitText(30, weight: FontWeight.w300, height: 1),
          ),
          Text(
            ' / ${setting == CabinSetting.rearFan ? 7 : 10}',
            style: cockpitText(11, color: CockpitStyle.muted),
          ),
        ],
      ),
      const SizedBox(height: 9),
      CabinLevelIndicator(
        value: value,
        max: setting == CabinSetting.rearFan ? 7 : 10,
      ),
      SizedBox(
        height: 17,
        child: pending == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '待確認 · ${_changeName(pending!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: cockpitText(10, color: CockpitStyle.amber),
                ),
              ),
      ),
    ],
  );
}

IconData _settingIcon(CabinSetting value) => switch (value) {
  CabinSetting.rearFan => Icons.air_rounded,
  CabinSetting.mediaVolume => Icons.music_note_rounded,
  CabinSetting.navVolume => Icons.volume_up_outlined,
};

String _settingName(CabinSetting value) => switch (value) {
  CabinSetting.rearFan => '後座風量',
  CabinSetting.mediaVolume => '音樂音量',
  CabinSetting.navVolume => '導航音量',
};
String _changeName(RequestedChange value) => switch (value) {
  RequestedChange.decrease => '降低一格',
  RequestedChange.increase => '提高一格',
  RequestedChange.keep => '維持原值',
  RequestedChange.remove => '取消變更',
};
String _phaseText(RepairPhase value) => switch (value) {
  RepairPhase.idle => '座艙已就緒，等你開口',
  RepairPhase.parsing => '正在理解；尚未執行',
  RepairPhase.awaitingClarification => '需要你補充一件事',
  RepairPhase.awaitingConfirmation => '確認這次的調整',
  RepairPhase.executing => '正在執行（模擬）',
  RepairPhase.completed => '這次調整已完成',
  RepairPhase.cancelled => '待執行需求已取消',
  RepairPhase.failed => '未完成，請檢查或重新說明',
  RepairPhase.indeterminate => '執行結果未知；請查證，不要重複執行',
};
