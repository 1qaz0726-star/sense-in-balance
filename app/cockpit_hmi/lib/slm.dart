// 端側 SLM —— Qwen2.5-1.5B q8 (.litertlm)，只在中控（平板）載入
//
// 模型不包進 APK（1.6 GB）。第一次使用時從 Hugging Face 公開 repo 下載，
// 或從手機裡已有的檔案匯入。下載可中斷續傳（HTTP Range）。
//
// 引擎與參數沿用 F:/slm_probe（2026-09-30 Tab S9 實測：GPU TTFT 1.65–2.01 s、
// 編造數字 0/12、該沉默而沉默 4/4）。改了任何一個參數，那組數字就不能再引用。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'rules.dart';
import 'repair_parser.dart' show kRepairSystemPrompt;
import 'slm_model_store.dart';

const String kModelUrl =
    'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/19edb84c69a0212f29a6ef17ba0d6f278b6a1614/'
    'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm';
const int kModelBytes = 1597931520;

/// 與 slm_probe 實測時逐字相同的系統提示。改這段 = 實測數字作廢。
const String kSystemPrompt =
    '你是車用語音助理。我會給你「已經決策完成」的座艙狀態，\n'
    '你只負責把決策講成一句給駕駛聽的話。你不需要做任何判斷或計算。\n'
    '\n'
    '最重要的三條（違反等於錯誤答案）：\n'
    '- 決策欄寫什麼動作，就只能講那個動作。不可以換成別的動作。\n'
    '  例如決策是「換氣」就不能講成「切換外循環」，那是兩件不同的事。\n'
    '- 決策欄寫「建議」或「稍後」時，語氣必須是從容的。\n'
    '  禁止使用「快」「立刻」「立即」「馬上」「趕快」這類催促詞。\n'
    '  只有決策欄本身寫「立即」時才可以急。\n'
    '- 不可以加入輸入裡沒有的理由、後果或影響。\n'
    '  例如輸入沒提到健康，就不能說「會影響健康」。\n'
    '\n'
    '其他規則：\n'
    '- 只輸出那一句話本身，不要解釋、不要引號、不要編號。\n'
    '- 嚴格遵守字數上限。字數吃緊時優先保留動作，代價可以不講。\n'
    '- 不可以出現任何輸入裡沒有的數字。\n'
    '- 緊急度是「不說話」時，只輸出 <silent>。\n'
    '- 必須是台灣人在車上會講的繁體中文口語，全部用正體字。\n'
    '- 禁用大陸用語：厘米、質量、信息、視頻、默認、數據、屏幕、傳感器、智能、請您、為您。\n'
    '- 禁用簡體字，「约」要寫「約」、「后」要寫「後」、「气」要寫「氣」。\n'
    '- 不要客套、不要條列、不要反問、不要複讀輸入。\n'
    '\n'
    '範例輸入：\n'
    '狀態: co2=1980↑ 車內=26 車外=31 循環=內 乘員=2 車速=90\n'
    '決策: 切換外循環 | 原因=CO2 1980 偏高且仍在上升 | 代價=車內將升溫約2度\n'
    '緊急度: 主動告知 | 上限: 15字\n'
    '範例輸出：二氧化碳偏高，切外循環會稍微變熱\n'
    '\n'
    '範例輸入：\n'
    '狀態: co2=2600↑↑ 車內=22 車外=12 循環=內 乘員=4 車速=110\n'
    '決策: 立即切換外循環 | 原因=CO2 2600 已達嗜睡風險\n'
    '緊急度: 安全 | 上限: 8字\n'
    '範例輸出：快切外循環，會想睡\n'
    '\n'
    '範例輸入：\n'
    '狀態: co2=420→ 車內=22 車外=24 循環=外 乘員=1 車速=35\n'
    '決策: 維持現狀 | 原因=各項數值正常\n'
    '緊急度: 不說話 | 上限: 0字\n'
    '範例輸出：<silent>\n'
    '\n'
    '範例輸入：\n'
    '狀態: co2=1340↑ 車內=26 車外=31 循環=內 乘員=2 車速=110\n'
    '決策: 建議稍後換氣 | 原因=CO2 1340 上升中\n'
    '緊急度: 主動告知 | 上限: 15字\n'
    '範例輸出：二氧化碳在升，等下記得換氣\n'
    '\n'
    '範例輸入：\n'
    '狀態: co2=2600↓ 車內=22 車外=31 循環=內 乘員=4 車速=35\n'
    '決策: 立即切換外循環 | 原因=CO2 2600 已達嗜睡風險 | 代價=車內將升溫約4度\n'
    '緊急度: 安全 | 上限: 8字\n'
    '範例輸出：快切外循環，會悶\n';

enum SlmPhase { checking, missing, downloading, present, loading, ready, error }

/// 在 runApp 之前呼叫（slm_probe 踩過：沒先初始化 install() 會丟 Bad state）
String? gGemmaInitError;
Future<void> initGemma() async {
  try {
    await FlutterGemma.initialize();
  } catch (e) {
    gGemmaInitError = '$e';
  }
}

class SlmGeneration {
  const SlmGeneration({
    required this.text,
    required this.elapsed,
    this.firstToken,
  });
  final String text;
  final Duration elapsed;
  final Duration? firstToken;
  Map<String, dynamic> toJson() => {
    'raw': text,
    'elapsed_ms': elapsed.inMicroseconds / 1000,
    'ttft_ms': firstToken == null ? null : firstToken!.inMicroseconds / 1000,
  };
}

class Slm extends ChangeNotifier {
  Slm._()
    : _modelStoreFactory = null,
      _installModelOverride = null,
      _loadModelOverride = null;

  @visibleForTesting
  Slm.forTesting({
    required Future<SlmModelStore> Function() modelStore,
    required Future<void> Function(File file) installModel,
    required Future<InferenceModel> Function(
      PreferredBackend backend,
      int maxTokens,
    )
    loadModel,
  }) : _modelStoreFactory = modelStore,
       _installModelOverride = installModel,
       _loadModelOverride = loadModel;

  static final Slm I = Slm._();
  final Future<SlmModelStore> Function()? _modelStoreFactory;
  final Future<void> Function(File file)? _installModelOverride;
  final Future<InferenceModel> Function(
    PreferredBackend backend,
    int maxTokens,
  )?
  _loadModelOverride;

  SlmPhase phase = SlmPhase.checking;
  double progress = 0;
  String detail = '';
  String backend = '';
  Duration? loadTime;
  Duration? verificationTime;
  SlmModelManifest selectedModel =
      const bool.fromEnvironment('SLM_PREFER_CABIN_V3')
      ? kCabinV3SlmManifest
      : kOriginalSlmManifest;
  File? _selectedFile;
  InferenceModel? _model;
  bool _cancel = false;
  bool _switching = false;
  Future<void> _queue = Future.value();

  bool get ready => phase == SlmPhase.ready;
  // Experiments are repair parsers unless explicitly validated for phrasing.
  bool get supportsPhrasing => selectedModel.id == kOriginalSlmManifest.id;
  bool get busy =>
      _switching || phase == SlmPhase.downloading || phase == SlmPhase.loading;

  void _set(SlmPhase p, [String d = '']) {
    phase = p;
    detail = d;
    notifyListeners();
  }

  Future<SlmModelStore> modelStore() async {
    if (_modelStoreFactory case final factory?) return factory();
    final directory = await getExternalStorageDirectory();
    if (directory == null) throw const FileSystemException('取不到 App 儲存目錄');
    return SlmModelStore(directory);
  }

  Future<File> _file() async =>
      _selectedFile ?? (await modelStore()).modelFile(selectedModel);

  /// The original remains the launch default. Experimental selection is explicit
  /// for this process; it never changes or replaces the original model file.
  Future<void> boot() async {
    if (phase != SlmPhase.checking && phase != SlmPhase.error) return;
    try {
      final file = await _file();
      if (await file.exists()) {
        await load();
      } else {
        final part = File('${file.path}.part');
        final got = await part.exists() ? await part.length() : 0;
        progress = got / selectedModel.bytes;
        _set(SlmPhase.missing, got > 0 ? '已下載 ${_gb(got)}，可續傳' : '');
      }
    } catch (e) {
      _set(SlmPhase.error, '$e');
    }
  }

  String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(2)} GB';

  Future<List<SlmModelManifest>> installedManifests() async =>
      (await modelStore()).manifests();

  /// Strict CPU/GPU means exactly the requested backend, with no silent fallback.
  /// file is used by the adb probe after SHA/size validation, without copying GBs.
  Future<void> selectModel(
    SlmModelManifest manifest, {
    File? file,
    PreferredBackend? preferredBackend,
    bool warmUp = true,
    int maxTokens = 2048,
  }) async {
    if (busy) throw StateError('模型正在準備，請稍後再切換');
    SlmModelManifest.fromJson(manifest.toJson());
    _switching = true;
    _set(SlmPhase.loading, '驗證並切換模型…');
    try {
      final store = await modelStore();
      final target = file ?? store.modelFile(manifest);
      final watch = Stopwatch()..start();
      await store.verify(target, manifest);
      verificationTime = watch.elapsed;
      await store.register(manifest);
      await _queue;
      await _model?.close();
      _model = null;
      backend = '';
      selectedModel = manifest;
      _selectedFile = file;
      await _loadVerified(target, preferredBackend, warmUp, maxTokens);
    } catch (e) {
      _set(SlmPhase.error, '切換失敗：$e');
      rethrow;
    } finally {
      _switching = false;
    }
  }

  /// Original download only; revision is pinned because HF main can change.
  Future<void> download() async {
    if (busy) return;
    if (selectedModel.id != kOriginalSlmManifest.id) {
      _set(SlmPhase.error, '實驗模型請以 manifest 與檔案匯入');
      return;
    }
    _cancel = false;
    final manifest = selectedModel;
    // Reserve the UI operation before its first await; a second download or
    // model switch must not write this same .part concurrently.
    _set(SlmPhase.downloading, '檢查下載檔…');
    var got = 0;
    HttpClient? client;
    IOSink? sink;
    SlmModelStore? store;
    try {
      store = await modelStore();
      var recovered = await store.prepareDownloadPart(manifest);
      got = recovered.resumableBytes;
      if (recovered.installedFile == null) {
        final part = File('${store.modelFile(manifest).path}.part');
        if (recovered.quarantinedPart != null) {
          _set(SlmPhase.downloading, '先前暫存驗證不符，已封存並重新下載…');
        } else {
          _set(SlmPhase.downloading, '連線中…');
        }
        client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
        final request = await client.getUrl(Uri.parse(manifest.source));
        if (got > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$got-');
        }
        final response = await request.close();
        if (response.statusCode == 200) {
          got = 0;
          sink = part.openWrite();
        } else if (response.statusCode == 206) {
          final range = response.headers.value(HttpHeaders.contentRangeHeader);
          if (range == null || !range.startsWith('bytes $got-')) {
            throw const HttpException('續傳範圍不符，未合併模型');
          }
          sink = part.openWrite(mode: FileMode.append);
        } else {
          throw HttpException('HTTP ${response.statusCode}');
        }
        var last = DateTime.now();
        await for (final chunk in response) {
          if (_cancel) throw const _Cancelled();
          got += chunk.length;
          if (got > manifest.bytes) {
            throw const FormatException('下載超過模型大小');
          }
          sink.add(chunk);
          final now = DateTime.now();
          if (now.difference(last).inMilliseconds >= 500) {
            last = now;
            progress = got / manifest.bytes;
            _set(SlmPhase.downloading, '${_gb(got)} / ${_gb(manifest.bytes)}');
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        recovered = await store.prepareDownloadPart(manifest);
        got = recovered.resumableBytes;
        if (recovered.installedFile == null) {
          if (recovered.quarantinedPart case final rejected?) {
            throw FileSystemException('下載檔案驗證不符，已封存；下次將重新下載', rejected.path);
          }
          throw FileSystemException(
            '下載未完整（$got / ${manifest.bytes} bytes），可續傳',
            part.path,
          );
        }
      }
      progress = 1;
      _set(SlmPhase.present);
      await load();
    } on _Cancelled {
      await sink?.close();
      _set(SlmPhase.missing, '已暫停，${_gb(got)}，可續傳');
    } catch (e) {
      await sink?.close();
      var recoveryDetail = '';
      // An oversized response may fail before the final integrity stage.
      // Recover any complete/oversized .part without deleting rejected bytes.
      if (store != null) {
        try {
          final recovered = await store.prepareDownloadPart(manifest);
          got = recovered.resumableBytes;
          if (recovered.quarantinedPart case final rejected?) {
            recoveryDetail = '；不符的暫存已封存至 ${rejected.path}';
          }
        } catch (_) {
          // Keep the original failure and every file if recovery itself fails.
        }
      }
      progress = (got / manifest.bytes).clamp(0.0, 1.0);
      _set(SlmPhase.error, '下載失敗：$e$recoveryDetail');
    } finally {
      client?.close(force: true);
    }
  }

  void cancelDownload() => _cancel = true;

  Future<void> importFile() => _pickModel(selectedModel);

  /// Experimental models require a separate exact-byte manifest before picking
  /// the large model; nothing infers identity from a user-chosen filename.
  Future<void> importExperiment() async {
    if (busy) return;
    try {
      final picked = await FilePicker.platform.pickFiles(withReadStream: true);
      if (picked == null || picked.files.isEmpty) return;
      final source = picked.files.single;
      if (source.size > 65536 || source.readStream == null) {
        throw const FormatException('manifest 檔案過大或無法讀取');
      }
      final bytes = await source.readStream!.fold<List<int>>([], (
        buffer,
        chunk,
      ) {
        if (buffer.length + chunk.length > 65536) {
          throw const FormatException('manifest 檔案過大');
        }
        return buffer..addAll(chunk);
      });
      final manifest = SlmModelManifest.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
      await _pickModel(manifest);
    } catch (e) {
      _set(SlmPhase.error, 'manifest 匯入失敗：$e');
    }
  }

  Future<void> _pickModel(SlmModelManifest manifest) async {
    if (busy) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        withReadStream: true,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final source = result.files.single;
      if (source.size != manifest.bytes || source.readStream == null) {
        throw FormatException('模型大小不符（應為 ${manifest.bytes} bytes）');
      }
      _set(SlmPhase.downloading, '匯入 ${manifest.label}…');
      await (await modelStore()).importStream(
        manifest,
        source.readStream!,
        onProgress: (done) {
          progress = done / manifest.bytes;
          if (done % (64 << 20) < (1 << 20)) notifyListeners();
        },
      );
      _set(SlmPhase.present);
      await selectModel(manifest);
    } catch (e) {
      _set(SlmPhase.error, '匯入失敗：$e');
    }
  }

  /// Existing callers retain GPU -> CPU fallback and the original warm-up.
  Future<void> load() async {
    if (_model != null && ready) return;
    if (_switching) return;
    try {
      await selectModel(selectedModel, file: _selectedFile);
    } catch (_) {
      // selectModel already records an actionable error for the settings page.
    }
  }

  Future<void> _loadVerified(
    File file,
    PreferredBackend? requested,
    bool warmUp,
    int maxTokens,
  ) async {
    if (gGemmaInitError != null) {
      throw StateError('FlutterGemma 初始化失敗：$gGemmaInitError');
    }
    if (maxTokens < 128 || maxTokens > 4096) {
      throw const FormatException('maxTokens 必須為 128–4096');
    }
    _set(SlmPhase.loading, '載入 ${selectedModel.label}…');
    loadTime = null;
    final watch = Stopwatch()..start();
    if (_installModelOverride case final install?) {
      await install(file);
    } else {
      await FlutterGemma.installModel(
        modelType: ModelType.qwen,
        fileType: ModelFileType.task,
      ).fromFile(file.path).install();
    }
    final candidates = requested == null
        ? [PreferredBackend.gpu, PreferredBackend.cpu]
        : [requested];
    final failures = <String>[];
    for (final candidate in candidates) {
      InferenceModel? candidateModel;
      try {
        watch.start();
        candidateModel = _loadModelOverride != null
            ? await _loadModelOverride(candidate, maxTokens)
            : await FlutterGemma.getActiveModel(
                maxTokens: maxTokens,
                preferredBackend: candidate,
              );
        // Loading time excludes warm-up, including failed candidates' warm-up.
        watch.stop();
        Duration? warmTime;
        if (warmUp) {
          _set(
            SlmPhase.loading,
            '${candidate.name.toUpperCase()} 首次暖機驗證中，可能較久（回應逾時 120 秒）…',
          );
          final warmWatch = Stopwatch()..start();
          final result = await _generateOnModel(
            candidateModel,
            supportsPhrasing ? kSystemPrompt : kRepairSystemPrompt,
            _warmUpPrompt(),
            timeout: const Duration(seconds: 120),
          );
          if (result.text.trim().isEmpty) throw StateError('暖機未產生文字');
          warmTime = warmWatch.elapsed;
        }
        // A backend that initializes but cannot create/generate a session must
        // never become public ready state. Probe warmUp=false remains explicit.
        _model = candidateModel;
        backend = candidate.name.toUpperCase();
        loadTime = watch.elapsed;
        _set(
          SlmPhase.ready,
          '$backend　載入 ${(loadTime!.inMilliseconds / 1000).toStringAsFixed(1)} s'
          '${warmTime == null ? '' : '・暖機 ${(warmTime.inMilliseconds / 1000).toStringAsFixed(1)} s'}'
          '${failures.isEmpty ? '' : '・已改用 $backend（${failures.join('; ')}）'}',
        );
        return;
      } catch (e) {
        watch.stop();
        failures.add('${candidate.name}: $e');
        try {
          await candidateModel?.close();
        } catch (closeError) {
          // Starting another native model while the failed one is not closed
          // could overlap resources; preserve an actionable error instead.
          throw StateError('${failures.join('; ')}; 模型關閉失敗：$closeError');
        }
      }
    }
    throw StateError(failures.join('; '));
  }

  String _warmUpPrompt() {
    if (!supportsPhrasing) {
      return '{"pending":{},"unresolved_text":null,"clarification":null,'
          '"user_text":"導航提示維持原樣。"}';
    }
    const state = {
      'co2': 420,
      'trend': '→',
      't_in': 26,
      't_out': 34,
      'recirc': '內',
      'occ': 2,
      'speed': 50,
    };
    return renderPrompt(state, decideCabin(state));
  }

  Future<void> unload() async {
    if (busy) throw StateError('模型正在準備');
    _switching = true;
    _set(SlmPhase.present);
    try {
      await _queue;
      await _model?.close();
      _model = null;
      backend = '';
    } finally {
      _switching = false;
    }
  }

  Future<String> phrase(String prompt) {
    if (!supportsPhrasing) {
      return Future.error(StateError('目前模型僅用於需求解析，原座艙告知使用模板'));
    }
    return generate(kSystemPrompt, prompt);
  }

  Future<String> generate(
    String systemPrompt,
    String prompt, {
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      (await generateTimed(systemPrompt, prompt, timeout: timeout)).text;

  /// Same unmodified message assembly/sampling for baseline and student.
  Future<SlmGeneration> generateTimed(
    String systemPrompt,
    String prompt, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final completer = Completer<SlmGeneration>();
    _queue = _queue.catchError((Object _) {}).then((_) async {
      final model = _model;
      if (model == null || !ready) {
        completer.completeError(StateError('模型未就緒'));
        return;
      }
      try {
        completer.complete(
          await _generateOnModel(model, systemPrompt, prompt, timeout: timeout),
        );
      } catch (e, stack) {
        completer.completeError(e, stack);
      }
    });
    return completer.future;
  }

  /// Used before ready only by candidate warm-up. Public requests still enter
  /// through the same queue/readiness check above, with their original timeout.
  Future<SlmGeneration> _generateOnModel(
    InferenceModel model,
    String systemPrompt,
    String prompt, {
    required Duration timeout,
  }) async {
    InferenceModelSession? session;
    try {
      final watch = Stopwatch()..start();
      Duration? first;
      session = await model.createSession(
        temperature: 0.2,
        randomSeed: 42,
        topK: 1,
      );
      await session.addQueryChunk(
        Message.text(text: '$systemPrompt\n\n$prompt', isUser: true),
      );
      final buffer = StringBuffer();
      await for (final piece in session.getResponseAsync().timeout(timeout)) {
        if (watch.elapsed > timeout) throw TimeoutException('模型解析逾時');
        if (piece.isNotEmpty) first ??= watch.elapsed;
        buffer.write(piece);
        if (buffer.length > 4096) throw const FormatException('模型輸出過長');
      }
      return SlmGeneration(
        text: buffer.toString(),
        elapsed: watch.elapsed,
        firstToken: first,
      );
    } finally {
      try {
        await session?.close();
      } catch (e) {
        debugPrint('SLM session close failed: $e');
      }
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
