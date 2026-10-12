// 端側 SLM —— Qwen2.5-1.5B q8 (.litertlm)，只在中控（平板）載入
//
// 模型不包進 APK（1.6 GB）。第一次使用時從 Hugging Face 公開 repo 下載，
// 或從手機裡已有的檔案匯入。下載可中斷續傳（HTTP Range）。
//
// 引擎與參數沿用 F:/slm_probe（2026-09-30 Tab S9 實測：GPU TTFT 1.65–2.01 s、
// 編造數字 0/12、該沉默而沉默 4/4）。改了任何一個參數，那組數字就不能再引用。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'rules.dart';

const String kModelUrl =
    'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/'
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

class Slm extends ChangeNotifier {
  Slm._();
  static final Slm I = Slm._();

  SlmPhase phase = SlmPhase.checking;
  double progress = 0; // 0–1
  String detail = '';
  String backend = '';
  Duration? loadTime;

  InferenceModel? _model;
  bool _cancel = false;
  Future<void> _queue = Future.value();

  bool get ready => phase == SlmPhase.ready;

  void _set(SlmPhase p, [String d = '']) {
    phase = p;
    detail = d;
    notifyListeners();
  }

  Future<File> _file() async {
    final d = await getExternalStorageDirectory();
    if (d == null) throw Exception('取不到 App 儲存目錄');
    return File('${d.path}/model.litertlm');
  }

  /// 開 App 時：檔案在就直接載入，不在就等使用者按下載
  Future<void> boot() async {
    if (phase != SlmPhase.checking && phase != SlmPhase.error) return;
    try {
      final f = await _file();
      if (await f.exists() && await f.length() == kModelBytes) {
        _set(SlmPhase.present);
        await load();
      } else {
        final part = File('${f.path}.part');
        final got = await part.exists() ? await part.length() : 0;
        progress = got / kModelBytes;
        _set(SlmPhase.missing, got > 0 ? '已下載 ${_gb(got)}，可續傳' : '');
      }
    } catch (e) {
      _set(SlmPhase.error, '$e');
    }
  }

  String _gb(int b) => '${(b / 1e9).toStringAsFixed(2)} GB';

  /// 從 Hugging Face 下載，支援續傳
  Future<void> download() async {
    if (phase == SlmPhase.downloading) return;
    _cancel = false;
    final f = await _file();
    final part = File('${f.path}.part');
    var got = await part.exists() ? await part.length() : 0;
    _set(SlmPhase.downloading, '連線中…');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse(kModelUrl));
      if (got > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$got-');
      final res = await req.close();
      if (res.statusCode == 200) {
        got = 0; // 伺服器不接受續傳，從頭來
        sink = part.openWrite();
      } else if (res.statusCode == 206) {
        sink = part.openWrite(mode: FileMode.append);
      } else {
        throw HttpException('HTTP ${res.statusCode}');
      }
      var last = DateTime.now();
      var lastBytes = got;
      await for (final chunk in res) {
        if (_cancel) throw const _Cancelled();
        sink.add(chunk);
        got += chunk.length;
        final now = DateTime.now();
        final dt = now.difference(last).inMilliseconds;
        if (dt >= 500) {
          final mbps = (got - lastBytes) / dt / 1000;
          last = now;
          lastBytes = got;
          progress = got / kModelBytes;
          _set(
            SlmPhase.downloading,
            '${_gb(got)} / ${_gb(kModelBytes)}　${mbps.toStringAsFixed(1)} MB/s',
          );
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final len = await part.length();
      if (len != kModelBytes) {
        throw Exception('檔案大小不符：$len（應為 $kModelBytes），請再按一次續傳');
      }
      await part.rename(f.path);
      progress = 1;
      _set(SlmPhase.present);
      await load();
    } on _Cancelled {
      await sink?.close();
      _set(SlmPhase.missing, '已暫停，${_gb(got)}，可續傳');
    } catch (e) {
      await sink?.close();
      progress = got / kModelBytes;
      _set(SlmPhase.missing, '下載中斷：$e（再按一次會從 ${_gb(got)} 續傳）');
    } finally {
      client.close(force: true);
    }
  }

  void cancelDownload() => _cancel = true;

  /// 從手機裡已有的 .litertlm 匯入（例如隊友用 LINE／隨身碟傳來的）
  Future<void> importFile() async {
    IOSink? sink;
    try {
      final res = await FilePicker.platform.pickFiles(
        withReadStream: true,
        allowMultiple: false,
      );
      if (res == null || res.files.isEmpty) return;
      final src = res.files.first;
      if (src.size != kModelBytes) {
        _set(SlmPhase.missing, '這個檔案大小是 ${src.size}，不是我們用的模型（應為 $kModelBytes）');
        return;
      }
      final f = await _file();
      final part = File('${f.path}.part');
      sink = part.openWrite();
      var done = 0;
      _set(SlmPhase.downloading, '匯入中…');
      await for (final c in src.readStream!) {
        sink.add(c);
        done += c.length;
        if (done % (64 << 20) < c.length) {
          progress = done / kModelBytes;
          _set(SlmPhase.downloading, '匯入 ${_gb(done)} / ${_gb(kModelBytes)}');
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await part.rename(f.path);
      _set(SlmPhase.present);
      await load();
    } catch (e) {
      await sink?.close();
      _set(SlmPhase.missing, '匯入失敗：$e');
    }
  }

  /// 先試 GPU（Tab S9 實測 TTFT 1.7 s），不行退 CPU（12 s，只能當保底）
  Future<void> load() async {
    if (_model != null) return _set(SlmPhase.ready);
    if (gGemmaInitError != null) {
      return _set(SlmPhase.error, 'FlutterGemma 初始化失敗：$gGemmaInitError');
    }
    _set(SlmPhase.loading, '載入模型…');
    final sw = Stopwatch()..start();
    try {
      final f = await _file();
      // 🔴 fileType 一定要明寫 task：預設 binary 會對 .litertlm 多套一層 Qwen chat marker
      await FlutterGemma.installModel(
        modelType: ModelType.qwen,
        fileType: ModelFileType.task,
      ).fromFile(f.path).install();
      for (final b in [PreferredBackend.gpu, PreferredBackend.cpu]) {
        try {
          _model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: b,
          );
          backend = b.name.toUpperCase();
          break;
        } catch (e) {
          detail = '$b 失敗：$e';
        }
      }
      if (_model == null) throw Exception(detail);
      loadTime = sw.elapsed;
      _set(
        SlmPhase.ready,
        '$backend　載入 ${(sw.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
      );
      _warmUp();
    } catch (e) {
      _set(SlmPhase.error, '載入失敗：$e');
    }
  }

  /// 暖機：載入後先空跑一句。實機第一次措辭要 6–7 秒（GPU 初次編譯），
  /// 先在背景吃掉這段，錄影時的第一句才不會特別慢。真正的措辭會排在它後面。
  void _warmUp() {
    const s = {
      'co2': 420,
      'trend': '→',
      't_in': 26,
      't_out': 34,
      'recirc': '內',
      'occ': 2,
      'speed': 50,
    };
    final sw = Stopwatch()..start();
    phrase(renderPrompt(s, decideCabin(s))).then((_) {
      detail =
          '$backend　載入 ${(loadTime!.inMilliseconds / 1000).toStringAsFixed(1)} s・'
          '暖機 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
      notifyListeners();
    }, onError: (_) {});
  }

  /// 措辭一句。呼叫會排隊，一次只跑一個 session（slm_probe 的參數：topK 1、temp 0.2、seed 42）
  Future<String> phrase(String prompt) => generate(kSystemPrompt, prompt);

  /// Separate prompts share the same model/queue. Parsing must not use the
  /// original phrasing prompt, which assumes the decision is already made.
  Future<String> generate(
    String systemPrompt,
    String prompt, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final c = Completer<String>();
    _queue = _queue.catchError((Object _) {}).then((_) async {
      final m = _model;
      if (m == null) return c.completeError(StateError('模型未就緒'));
      InferenceModelSession? s;
      try {
        final sw = Stopwatch()..start();
        s = await m.createSession(temperature: 0.2, randomSeed: 42, topK: 1);
        await s.addQueryChunk(
          Message.text(text: '$systemPrompt\n\n$prompt', isUser: true),
        );
        final buf = StringBuffer();
        await for (final piece in s.getResponseAsync().timeout(timeout)) {
          if (sw.elapsed > timeout) throw TimeoutException('模型解析逾時');
          buf.write(piece);
          if (buf.length > 4096) throw const FormatException('模型輸出過長');
        }
        c.complete(buf.toString());
      } catch (e) {
        c.completeError(e);
      } finally {
        try {
          await s?.close();
        } catch (e) {
          debugPrint('SLM session close failed: $e');
        }
      }
    });
    return c.future;
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
