import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'cockpit_design.dart';
import 'cabin_policy.dart';
import 'cabin_cockpit_source.dart';
import 'cabin_coordination_widgets.dart';
import 'cockpit_alert_slot.dart';
import 'cockpit_instruments.dart';
import 'hub.dart' as original;
import 'protocol.dart';
import 'repair_hub.dart';
import 'repair_collaboration.dart';
import 'repair_collaboration_widgets.dart';
import 'repair_cloud_model.dart';
import 'repair_cloud_speech.dart';
import 'owner_memory.dart';
import 'repair_parser.dart';
import 'repair_remote_model.dart';
import 'repair_task.dart';
import 'repair_speech.dart';
import 'setup.dart';
import 'slm.dart';
import 'voice.dart';

class RepairScreen extends StatefulWidget {
  const RepairScreen({super.key});
  @override
  State<RepairScreen> createState() => _RepairScreenState();
}

class _RepairScreenState extends State<RepairScreen> {
  final input = TextEditingController();
  late final RepairController controller;
  late final RepairCollaboration collaboration;
  late final RepairHub hub;
  late final RemoteRepairModel? remoteModel;
  late final MockCabinActuator actuator;
  CabinPolicy? policy;
  static const coordinationEnabled = bool.fromEnvironment('CABIN_COORDINATION');
  Timer? coordinationWatch;
  String? sourceSession;
  int drivingSequence = 0, episodeNumber = 0;
  String drivingEpisode = 'driving-baseline';
  CabinDrivingMode drivingMode = CabinDrivingMode.manual;
  bool drivingSourceOnline = true;
  bool previousAttentionBlocked = true;
  CabinCockpitSource? cockpitSource;
  String? sessionNotice;
  final Set<CabinSetting> removedSettings = {};
  Map<String, dynamic> get executionIdentity => {
    'cabin_session_id': policy!.sessionId,
    'profile_id': policy!.profile.id,
    'profile_revision': policy!.profile.revision,
  };
  final cockpit = original.Hub.I;
  bool ownsCockpit = false;
  bool showInstruments = false;
  bool lastFresh = false;
  Timer? cockpitWatch;
  String address = '正在準備另一台平板的連線…';
  final speech = RepairSpeechInput();
  bool speechAvailable = false;
  bool speechListening = false;
  int speechRequest = 0;
  String? speechStatus;
  String? previousTaskId;
  Map<CabinSetting, RequestedChange> previousPending = const {};
  Set<CabinSetting> changedSettings = {};

  /// Hybrid AI：有建置金鑰才有雲端；沒有金鑰就是純離線版。
  late final CloudAssist? cloudAssist;
  final cloudLink = CloudLink();
  bool get cloudOnline => cloudLink.online;
  int cloudLessons = 0;
  Timer? cloudWatch;
  final CloudSpeech? cloudSpeech = CloudSpeech.fromEnvironment();
  bool speechRecording = false;

  /// 車主記憶：雲端教一次、駕駛確認過就記住；只存在這台裝置。
  OwnerMemory ownerMemory = OwnerMemory();
  String? lastSubmittedText;
  ({
    String taskId,
    String text,
    String source,
    Map<CabinSetting, RequestedChange> pending,
  })?
  learnCandidate;

  /// 連網且有雲端辨識時，麥克風改成「錄音→雲端（台語／華語）」；否則照舊用離線辨識。
  bool get cloudSpeechReady => cloudSpeech != null && cloudOnline;

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
    // 2026-10-13：接回原作的車內語音（安全警示、換氣告知），與原「中控」模式同一套 TTS。
    cockpit.onSpeak = (t, urgent) {
      policy?.refresh();
      if (urgent || policy?.blocked != true) Voice.I.say(t, urgent: urgent);
    };
    unawaited(Voice.I.init());
    cockpitWatch = Timer.periodic(const Duration(seconds: 1), (_) {
      final fresh = cockpitFresh;
      if (mounted && fresh != lastFresh) setState(() => lastFresh = fresh);
    });
    cloudAssist = cloudAssistFromEnvironment(
      link: cloudLink,
      onLesson: (_) {
        if (mounted) setState(() => cloudLessons++);
      },
    );
    if (cloudAssist != null) {
      Future<void> probe() async {
        final changed = await cloudLink.check();
        // 一連上網就先把台語辨識叫醒，台上第一句不用等冷啟動。
        if (changed && cloudLink.online) unawaited(cloudSpeech?.warm());
        if (mounted && changed) setState(() {});
      }

      unawaited(probe());
      cloudWatch = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(probe()),
      );
    }
    unawaited(() async {
      try {
        final dir = await getApplicationSupportDirectory();
        final memory = OwnerMemory(file: File('${dir.path}/owner_memory.json'));
        await memory.load();
        if (mounted) setState(() => ownerMemory = memory);
      } catch (_) {
        // 存不了檔就只放在記憶體，不影響其他功能。
      }
    }());
    actuator = MockCabinActuator(
      supports: coordinationEnabled
          ? (setting) => policy?.profile.supported.contains(setting) == true
          : null,
      executionContext: coordinationEnabled ? () => executionIdentity : null,
    );
    controller = RepairController(
      executionContext: coordinationEnabled ? () => executionIdentity : null,
      parseTimeout: Duration(seconds: remoteModel == null ? 60 : 30),
      parser: RepairParser(
        (system, prompt) {
          if (!modelReady) return Future.error(StateError('請先準備模型'));
          return remoteModel?.generate(system, prompt) ??
              Slm.I.generate(
                system,
                prompt,
                timeout: const Duration(seconds: 55),
              );
        },
        onTrace: const bool.fromEnvironment('REPAIR_EVAL_LOG')
            ? (trace) => debugPrint(
                'REPAIR_EVAL ${jsonEncode({...trace, 'backend': remoteModel == null ? Slm.I.backend : 'PC local', 'model_id': remoteModel?.model ?? Slm.I.selectedModel.id})}',
              )
            : null,
        cloud: cloudAssist,
        recall: (text) => ownerMemory.recall(text)?.changes,
      ).call,
      actuator: actuator.call,
    );
    if (coordinationEnabled) policy = CabinPolicy(controller);
    collaboration = RepairCollaboration(controller, policy: policy);
    if (policy != null) {
      _registerCoordinationSources();
      policy!.addListener(_attentionChanged);
      // Register before RepairHub subscribes: a newly published priority
      // signal updates the host gate before that signal reaches clients.
      cockpit.addListener(_sampleCoordinationSources);
      coordinationWatch = Timer.periodic(const Duration(seconds: 1), (_) {
        _sampleCoordinationSources();
      });
    }
    controller.addListener(_capturePendingChanges);
    hub = RepairHub(
      controller,
      collaboration: collaboration,
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
    unawaited(_checkSpeech());
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
    coordinationWatch?.cancel();
    if (policy != null) cockpit.removeListener(_sampleCoordinationSources);
    cloudWatch?.cancel();
    cockpit.onSpeak = null;
    unawaited(hub.stop());
    if (ownsCockpit) unawaited(cockpit.stop());
    controller.removeListener(_capturePendingChanges);
    collaboration.cancel();
    collaboration.dispose();
    policy?.removeListener(_attentionChanged);
    policy?.dispose();
    controller.dispose();
    speech.dispose();
    ++speechRequest;
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
    lastSubmittedText = value;
    final accepted = active
        ? await collaboration.revise(value)
        : await collaboration.newTask(value);
    if (accepted && mounted) input.clear();
  }

  void _capturePendingChanges() {
    final task = controller.snapshot;
    _learnFromTask(task);
    if (task.taskId != previousTaskId) {
      changedSettings = {};
      removedSettings.clear();
    } else if (task.phase != RepairPhase.parsing) {
      final changed = {
        for (final setting in CabinSetting.values)
          if (previousPending[setting] != task.pending[setting]) setting,
      };
      if (changed.isNotEmpty) changedSettings = changed;
      if (task.phase == RepairPhase.awaitingConfirmation ||
          task.phase == RepairPhase.awaitingClarification) {
        for (final setting in previousPending.keys) {
          if (!task.pending.containsKey(setting)) removedSettings.add(setting);
        }
        removedSettings.removeWhere(task.pending.containsKey);
      }
    }
    previousTaskId = task.taskId;
    previousPending = task.pending;
  }

  void _registerCoordinationSources() {
    final current = policy!;
    sourceSession = current.sessionId;
    drivingSequence = 0;
    drivingEpisode = '${current.sessionId}-driving-baseline';
    drivingMode = CabinDrivingMode.manual;
    drivingSourceOnline = true;
    current.registerSource(CabinPolicy.drivingSource, '$sourceSession-driving');
    current.registerSource(CabinPolicy.safetySource, '$sourceSession-safety');
    cockpitSource = CabinCockpitSource(current, '$sourceSession-safety');
    // Registration alone does not assert a clear source. The first real
    // simulator sample arrives via the next one-second heartbeat.
  }

  void _sampleCoordinationSources() {
    final current = policy;
    if (current == null || sourceSession != current.sessionId) return;
    if (drivingSourceOnline) {
      current.observe(
        CabinAttentionFrame(
          sourceId: CabinPolicy.drivingSource,
          sourceSession: '$sourceSession-driving',
          sequence: ++drivingSequence,
          episodeId: drivingEpisode,
          sampledAt: current.monotonicNow,
          mode: drivingMode,
          active: drivingMode == CabinDrivingMode.handoverRequested,
          known: drivingMode != CabinDrivingMode.unknown,
        ),
      );
    }
    cockpitSource?.sample(
      cockpit.last,
      running: cockpit.running,
      wallNowSeconds: DateTime.now().microsecondsSinceEpoch / 1000000,
    );
    current.refresh();
  }

  void _attentionChanged() {
    final current = policy!;
    if (current.blocked &&
        !previousAttentionBlocked &&
        cockpit.last?.decision.urgency != Urgency.safety) {
      unawaited(Voice.I.stop());
    }
    if (current.blocked &&
        !previousAttentionBlocked &&
        current.mode == CabinDrivingMode.handoverRequested) {
      unawaited(Voice.I.say('接管提醒（模擬）', urgent: true));
    }
    previousAttentionBlocked = current.blocked;
  }

  void _setDrivingMode(CabinDrivingMode mode) {
    if (mode == CabinDrivingMode.handoverRequested &&
        drivingMode != CabinDrivingMode.handoverRequested) {
      drivingEpisode = '$sourceSession-driving-${++episodeNumber}';
    }
    drivingMode = mode;
    drivingSourceOnline = true;
    _sampleCoordinationSources();
    if (mounted) setState(() {});
  }

  void _switchCabinProfile(CabinProfile profile) {
    final parked =
        cockpitFresh &&
        '${cockpit.last?.vehicle?['gear'] ?? ''}'.toUpperCase() == 'P';
    if (!collaboration.startCabinSession(profile, parked: parked)) {
      setState(() => sessionNotice = '請先模擬停車，並結束或取消目前需求，再切換能力設定。');
      return;
    }
    actuator.reset();
    _registerCoordinationSources();
    input.clear();
    removedSettings.clear();
    previousPending = const {};
    previousTaskId = null;
    setState(() => sessionNotice = '${profile.label}已啟用；請重新配對駕駛屏。');
  }

  /// 雲端（或記憶）提出、駕駛確認後完成的需求，寫進車主記憶。
  void _learnFromTask(RepairSnapshot task) {
    final id = task.taskId;
    if (id == null) return;
    final candidate = learnCandidate;
    if (task.phase == RepairPhase.awaitingConfirmation) {
      final source = task.patchSource;
      if ((source == 'cloud' || source == 'memory') &&
          lastSubmittedText != null) {
        learnCandidate = (
          taskId: id,
          text: lastSubmittedText!,
          source: source!,
          pending: task.pending,
        );
      } else if (candidate != null && candidate.taskId == id) {
        // 同一個任務後來被局部修改：記住駕駛最後確認的版本。
        learnCandidate = (
          taskId: id,
          text: candidate.text,
          source: candidate.source,
          pending: task.pending,
        );
      }
    } else if (task.phase == RepairPhase.completed &&
        candidate != null &&
        candidate.taskId == id) {
      learnCandidate = null;
      unawaited(
        ownerMemory
            .remember(
              text: candidate.text,
              changes: candidate.pending,
              source: candidate.source,
            )
            .then((_) {
              if (mounted) setState(() {});
            }),
      );
    } else if (task.phase == RepairPhase.cancelled && candidate?.taskId == id) {
      learnCandidate = null;
    }
  }

  void _showMemory() {
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          backgroundColor: CockpitStyle.panel,
          title: const Text('車主記憶（只存在這台車上）'),
          content: SizedBox(
            width: 440,
            child: ownerMemory.entries.isEmpty
                ? const Text('還沒有記憶。連網時由雲端理解、駕駛確認過的需求會記在這裡，之後斷網也能用。')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final entry in ownerMemory.entries)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('「${entry.phrase}」'),
                          subtitle: Text(
                            '${entry.changes.entries.map((e) => '${_settingName(e.key)}${_changeName(e.value)}').join('、')}'
                            '${entry.uses > 0 ? '・用過 ${entry.uses} 次' : ''}',
                          ),
                          trailing: IconButton(
                            tooltip: '刪除這條記憶',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await ownerMemory.forget(entry);
                              setLocal(() {});
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('關閉'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkSpeech() async {
    try {
      final available = await speech.isAvailable();
      if (mounted) setState(() => speechAvailable = available);
      // 有離線辨識服務但缺繁中語言包時，請系統下載（只下載語言包，不改走雲端）。
      if (available) {
        final status = await speech.prepareLanguage();
        if (mounted && status == 'downloading') {
          setState(() => speechStatus = '正在下載繁體中文離線語音，完成前請先輸入文字。');
        }
      }
    } catch (_) {
      if (mounted) setState(() => speechAvailable = false);
    }
  }

  /// 連網時：第一次按開始錄音，第二次按送雲端辨識；結果一樣只填入文字，由使用者核對後送出。
  Future<void> _cloudSpeech() async {
    final cloud = cloudSpeech!;
    if (!speechRecording) {
      try {
        await speech.startRecording();
        if (mounted) {
          setState(() {
            speechRecording = true;
            speechListening = true;
            speechStatus = '正在聆聽（雲端）；說完再按一次。';
          });
        }
      } catch (_) {
        if (mounted) setState(() => speechStatus = '無法錄音，請用文字輸入。');
      }
      return;
    }
    final request = ++speechRequest;
    setState(() {
      speechRecording = false;
      speechStatus = '雲端辨識中…';
    });
    try {
      final audio = await speech.stopRecording();
      final result = await cloud.transcribe(audio);
      if (mounted && request == speechRequest) {
        input.text = result.text;
        speechStatus = result.lang == 'nan'
            ? '雲端台語辨識・請核對後再提交'
            : '雲端語音辨識・請核對後再提交';
      }
    } on TaigiWarming {
      if (mounted && request == speechRequest) {
        speechStatus = '台語辨識準備中，請稍等幾秒再說一次。';
      }
    } catch (_) {
      if (mounted && request == speechRequest) {
        speechStatus = '雲端辨識沒有完成，請再說一次或輸入文字。';
      }
    } finally {
      if (mounted && request == speechRequest) {
        setState(() => speechListening = false);
      }
    }
  }

  Future<void> _listenSpeech() async {
    if (speechRecording || (cloudSpeechReady && !speechListening)) {
      return _cloudSpeech();
    }
    if (speechListening) {
      ++speechRequest;
      try {
        await speech.cancel();
      } catch (_) {
        if (mounted) speechStatus = '語音已停止，請用文字輸入。';
      } finally {
        if (mounted) setState(() => speechListening = false);
      }
      return;
    }
    final request = ++speechRequest;
    setState(() {
      speechListening = true;
      speechStatus = '正在聆聽；可按「停止聆聽」。';
    });
    try {
      final text = await speech.listen(language: 'zh-TW');
      if (mounted &&
          request == speechRequest &&
          text != null &&
          text.trim().isNotEmpty) {
        input.text = text.trim();
        speechStatus = '辨識文字已填入；請核對後再提交候選。';
      }
    } on PlatformException catch (error) {
      if (mounted && request == speechRequest) {
        speechStatus = error.message ?? '離線語音未就緒，請用文字輸入。';
      }
    } on UnsupportedError catch (error) {
      if (mounted && request == speechRequest) {
        speechStatus = '${error.message}；請用文字輸入。';
      }
    } catch (_) {
      if (mounted && request == speechRequest) {
        speechStatus = '無法使用離線語音，請用文字輸入。';
      }
    } finally {
      if (mounted && request == speechRequest) {
        setState(() => speechListening = false);
      }
    }
  }

  void showConnection() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CockpitStyle.panel,
      shape: const RoundedRectangleBorder(),
      builder: (sheetContext) => AnimatedBuilder(
        animation: Listenable.merge([collaboration, remoteModel ?? Slm.I]),
        builder: (_, _) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '連接駕駛屏',
                    style: cockpitText(22, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    collaboration.pairingCode,
                    style: cockpitText(
                      38,
                      letterSpacing: 8,
                      weight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '駕駛在另一個螢幕輸入此六位碼。\n配對後才可授權與確認；這裡不會直接套用。',
                    style: cockpitText(14, color: CockpitStyle.muted),
                  ),
                  const SizedBox(height: 20),
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
                          MaterialPageRoute(
                            builder: (_) => const ModelSetupPage(),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
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
            collaboration,
            remoteModel ?? Slm.I,
            cockpit,
            if (policy != null) policy!,
          ]),
          builder: (context, _) {
            final task = controller.snapshot;
            return Column(
              children: [
                _header(),
                CockpitAlertSlot(event: cockpit.last, fresh: cockpitFresh),
                if (MediaQuery.sizeOf(context).width < 1200)
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
                if (policy != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: CabinAttentionStrip(
                      contextData: policy!.toJson(),
                      completed: task.phase == RepairPhase.completed,
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
                          '乘客提出需求 · 駕駛確認後才套用',
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
              policy?.profile.label ?? 'SENSE IN BALANCE',
              style: cockpitText(
                9,
                color: CockpitStyle.muted,
                letterSpacing: 2.4,
              ),
            ),
          ],
        ),
        if (MediaQuery.sizeOf(context).width >= 1200) ...[
          const SizedBox(width: 56),
          _viewPicker(),
        ],
        const Spacer(),
        if (MediaQuery.sizeOf(context).width >= 620) ...[
          TextButton(onPressed: _showSimulation, child: const Text('展示情境')),
          const SizedBox(width: 20),
        ],
        if (MediaQuery.sizeOf(context).width >= 1100) ...[
          Text(
            modelReady ? '本地 AI 就緒' : 'AI 準備中',
            style: cockpitText(12, color: CockpitStyle.muted),
          ),
          if (cloudAssist != null &&
              MediaQuery.sizeOf(context).width >= 1400) ...[
            const SizedBox(width: 12),
            _cloudStatus(),
          ],
          const SizedBox(width: 24),
        ],
        // 直放（窄螢幕）也要看得出現在是離線還是連網：決賽 S21 直放。
        if (MediaQuery.sizeOf(context).width < 620 &&
            MediaQuery.sizeOf(context).width >= 500 &&
            cloudAssist != null) ...[
          _cloudStatus(compact: true),
          const SizedBox(width: 6),
        ],
        if (MediaQuery.sizeOf(context).width < 1100)
          IconButton(
            tooltip: '車主記憶',
            onPressed: _showMemory,
            icon: Badge(
              isLabelVisible: ownerMemory.entries.isNotEmpty,
              label: Text('${ownerMemory.entries.length}'),
              child: const Icon(
                Icons.psychology_outlined,
                size: 19,
                color: CockpitStyle.muted,
              ),
            ),
          )
        else ...[
          TextButton(
            onPressed: _showMemory,
            child: Text('車主記憶 ${ownerMemory.entries.length}'),
          ),
          const SizedBox(width: 8),
        ],
        if (MediaQuery.sizeOf(context).width >= 460) const CockpitClock(),
        const SizedBox(width: 16),
        if (MediaQuery.sizeOf(context).width >= 620)
          TextButton(onPressed: showConnection, child: const Text('連接駕駛屏'))
        else
          IconButton(
            tooltip: '連接駕駛屏',
            onPressed: showConnection,
            icon: const Icon(Icons.link, size: 19, color: CockpitStyle.muted),
          ),
      ],
    ),
  );

  /// 頂部列的雲端狀態：連網時亮、離線時灰；連帶顯示本次累積的雲端教材數。
  Widget _cloudStatus({bool compact = false}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cloudOnline ? CockpitStyle.accent : CockpitStyle.muted,
        ),
      ),
      const SizedBox(width: 6),
      Text(
        compact
            ? (cloudOnline ? '雲端增強' : '離線')
            : cloudOnline
            ? '雲端增強可用${cloudLessons > 0 ? '・教材 $cloudLessons 筆' : ''}'
            : '離線・本地運作',
        style: cockpitText(
          12,
          color: cloudOnline ? CockpitStyle.accent : CockpitStyle.muted,
        ),
      ),
    ],
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
              instruments ? '行車儀表' : '乘客協助',
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
          animation: Listenable.merge([
            cockpit,
            controller,
            if (policy != null) policy!,
          ]),
          builder: (_, _) => SingleChildScrollView(
            child: _simulationStrip(coordinationDetails: true),
          ),
        ),
      ),
    );
  }

  Widget _simulationStrip({bool coordinationDetails = false}) => Container(
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
              if (const bool.fromEnvironment('REPAIR_DESKTOP_DEMO'))
                _sceneControl(
                  '安排一項誤解',
                  Icons.edit_note,
                  controller.snapshot.phase == RepairPhase.awaitingConfirmation
                      ? () => collaboration.injectDemoMisunderstanding()
                      : null,
                ),
            ],
          ),
        ),
        if (coordinationDetails && policy != null) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Text(
            '注意力模式 · 全為本機模擬來源',
            style: cockpitText(13, color: CockpitStyle.accent),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _sceneControl(
                '人工駕駛（模擬）',
                Icons.person_outline,
                () => _setDrivingMode(CabinDrivingMode.manual),
              ),
              _sceneControl(
                '輔助駕駛（模擬）',
                Icons.route_outlined,
                () => _setDrivingMode(CabinDrivingMode.assisted),
              ),
              _sceneControl(
                '接管提醒（模擬）',
                Icons.front_hand_outlined,
                () => _setDrivingMode(CabinDrivingMode.handoverRequested),
              ),
              _sceneControl(
                drivingSourceOnline ? '中斷模式來源' : '恢復模式來源',
                Icons.sync_problem_outlined,
                () {
                  drivingSourceOnline = !drivingSourceOnline;
                  if (drivingSourceOnline) _sampleCoordinationSources();
                  setState(() {});
                },
              ),
            ],
          ),
          Text(
            '輔助駕駛仍須人全程注意；解除提醒不會自動執行需求。來源中斷超過 3 秒會阻擋確認。',
            style: cockpitText(11, color: CockpitStyle.muted),
          ),
          const SizedBox(height: 14),
          Text(
            '能力設定 · ${policy!.profile.label}',
            style: cockpitText(13, color: CockpitStyle.accent),
          ),
          Wrap(
            spacing: 14,
            children: [
              _sceneControl(
                '座艙 A · 三項可控',
                Icons.directions_car_outlined,
                () => _switchCabinProfile(CabinProfile.a),
              ),
              _sceneControl(
                '座艙 B · 後風無介面',
                Icons.directions_car_outlined,
                () => _switchCabinProfile(CabinProfile.b),
              ),
            ],
          ),
          Text(
            sessionNotice ?? '僅在模擬停車且需求已結束／取消時切換；切換後需重新配對與授權。',
            style: cockpitText(11, color: CockpitStyle.muted),
          ),
        ],
      ],
    ),
  );

  Widget _sceneControl(String label, IconData icon, VoidCallback? action) =>
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
    final collaborationState = collaboration.toJson();
    final demoFault =
        collaborationState['demo_fault'] ??
        collaborationState['demo_fault_source'];
    final busy =
        task.phase == RepairPhase.parsing ||
        task.phase == RepairPhase.executing ||
        task.phase == RepairPhase.indeterminate;
    final revising =
        task.phase == RepairPhase.awaitingConfirmation ||
        task.phase == RepairPhase.awaitingClarification ||
        task.phase == RepairPhase.failed;
    final canCancel = task.phase == RepairPhase.parsing || revising;
    final canInput = !busy && (!revising || collaboration.canRevise);
    final contextData = policy?.toJson();
    final blocked = cabinAttentionBlocked(contextData);
    final unsupported = cabinUnsupported(contextData);
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
                  '乘客協助 · 不用重講',
                  style: cockpitText(
                    12,
                    color: CockpitStyle.muted,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  blocked && revising
                      ? '需求保留，先讓駕駛專注'
                      : unsupported.isNotEmpty && revising
                      ? '有一項這台車不能做'
                      : revising
                      ? '只改這一項，其餘保留'
                      : '先提出需求，駕駛來確認',
                  style: cockpitText(27, weight: FontWeight.w400),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: input,
                  minLines: 2,
                  maxLines: 2,
                  maxLength: 500,
                  enabled: canInput && !speechListening,
                  style: cockpitText(19),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: revising
                        ? '例如：風量先不用改，其餘照剛剛。'
                        : '後座風小一點，音樂也小一點，\n導航提示不要變。',
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed:
                          speechListening ||
                              (canInput &&
                                  (speechAvailable || cloudSpeechReady))
                          ? _listenSpeech
                          : null,
                      icon: Icon(
                        speechListening ? Icons.stop : Icons.mic_none,
                        size: 17,
                      ),
                      label: Text(
                        speechRecording
                            ? '說完了'
                            : speechListening
                            ? '停止聆聽'
                            : '說出需求',
                      ),
                    ),
                    if (!speechAvailable)
                      Text(
                        '離線語音未就緒，請用文字',
                        style: cockpitText(11, color: CockpitStyle.muted),
                      ),
                  ],
                ),
                if (speechStatus != null)
                  Text(
                    speechStatus!,
                    style: cockpitText(12, color: CockpitStyle.muted),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: !canInput || speechListening
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
                      onPressed: !canInput || speechListening || !modelReady
                          ? null
                          : submit,
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
                            ? '更新候選摘要'
                            : '送給駕駛看',
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
                if (task.patchSource == 'cloud' ||
                    task.patchSource == 'memory') ...[
                  const SizedBox(height: 8),
                  Text(
                    task.patchSource == 'memory'
                        ? '來自車主記憶（之前確認過）・仍需駕駛確認'
                        : task.clarification == null
                        ? '雲端解讀（連網增強）・確認後會記住'
                        : '雲端也無法確定，請補充一項',
                    style: cockpitText(13, color: CockpitStyle.accent),
                  ),
                ],
                if (demoFault is Map) ...[
                  const SizedBox(height: 10),
                  DemoFaultNotice(fault: demoFault),
                ],
                if (task.phase == RepairPhase.idle ||
                    task.phase == RepairPhase.cancelled) ...[
                  const SizedBox(height: 8),
                  Text(
                    '先整理候選，設定不會改動。\n駕駛授權後可局部修正，最後由駕駛確認模擬套用。',
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
                if (task.phase != RepairPhase.indeterminate) ...[
                  const SizedBox(height: 12),
                  if (changedSettings.isNotEmpty &&
                      task.revision > 1 &&
                      revising)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        '這次只改：${changedSettings.map(_settingName).join('、')}；其餘保留',
                        style: cockpitText(13, color: CockpitStyle.accent),
                      ),
                    ),
                  PassengerCandidateEditor(
                    pending: task.pending,
                    acknowledgedItems: task.result?.items ?? const {},
                    canRevise:
                        collaboration.canRevise && !busy && !speechListening,
                    changedSettings: changedSettings,
                    unsupported: unsupported,
                    removedSettings: removedSettings,
                    onPatch: (setting, change) =>
                        collaboration.directPatch(setting, change),
                  ),
                ],
                if (task.clarification != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    task.clarification!,
                    style: cockpitText(16, color: CockpitStyle.amber),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '逐項按鈕可改候選；請在上方回答，完成釐清後再確認。',
                    style: cockpitText(12, color: CockpitStyle.muted),
                  ),
                ],
                if (task.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    task.error!,
                    style: cockpitText(14, color: CockpitStyle.amber),
                  ),
                  Text(
                    '駕駛授權後，可用上方「改這一項」逐項提出候選，最後仍須駕駛確認。',
                    style: cockpitText(12, color: CockpitStyle.muted),
                  ),
                ],
                if (collaboration.error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    collaboration.error!,
                    style: cockpitText(13, color: CockpitStyle.amber),
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
        Container(
          padding: const EdgeInsets.only(top: 12),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: CockpitStyle.line, width: .5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      revising
                          ? blocked
                                ? '駕駛確認暫停 · 需求已保留'
                                : unsupported.isNotEmpty
                                ? '先處理受限項目 · 其餘保留'
                                : policy?.resumeRequired == true
                                ? '等待駕駛確認最新內容'
                                : '等待駕駛確認'
                          : task.phase == RepairPhase.completed
                          ? '駕駛已確認 · 模擬回報已收到'
                          : '候選不會直接執行',
                      style: cockpitText(15, color: CockpitStyle.accent),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _authorizationText(task),
                      style: cockpitText(11, color: CockpitStyle.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              TextButton(
                onPressed: canCancel ? () => collaboration.cancel() : null,
                child: const Text('取消需求'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _authorizationText(RepairSnapshot task) {
    final state = collaboration.toJson();
    if (state['paired'] != true || state['driver_online'] != true) {
      return '駕駛屏未連接 · 可先提出候選，尚未套用';
    }
    if (collaboration.canRevise) {
      final expiry = state['authorization_expires_at'];
      final seconds = expiry is num
          ? ((expiry - DateTime.now().millisecondsSinceEpoch) / 1000)
                .ceil()
                .clamp(0, 120)
          : 0;
      return '駕駛已授權本次需求 · 剩餘 $seconds 秒';
    }
    final expiry = state['authorization_expires_at'];
    if (expiry is num &&
        expiry <= DateTime.now().millisecondsSinceEpoch &&
        state['authorization_task_id'] == task.taskId) {
      return '授權已到期 · 請駕駛重新授權後再修改';
    }
    return '駕駛已連接 · 修改前須由駕駛授權';
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
                  : policy != null &&
                        !policy!.profile.readable.contains(setting)
                  ? null
                  : actuator.state[setting],
              readable:
                  policy == null || policy!.profile.readable.contains(setting),
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
  const _LevelTile({
    required this.setting,
    required this.value,
    this.pending,
    this.readable = true,
  });
  final CabinSetting setting;
  final int? value;
  final RequestedChange? pending;
  final bool readable;

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
            readable
                ? ' / ${setting == CabinSetting.rearFan ? 7 : 10}'
                : ' / 不提供',
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
  RepairPhase.idle => '可先提出候選需求，尚未執行',
  RepairPhase.parsing => '正在理解；尚未執行',
  RepairPhase.awaitingClarification => '需補充一項；駕駛授權後再修改',
  RepairPhase.awaitingConfirmation => '候選已整理，等待駕駛確認',
  RepairPhase.executing => '正在執行（模擬）',
  RepairPhase.completed => '這次調整已完成',
  RepairPhase.cancelled => '待執行需求已取消',
  RepairPhase.failed => '未完成，請檢查或重新說明',
  RepairPhase.indeterminate => '執行結果未知；請查證，不要重複執行',
};
