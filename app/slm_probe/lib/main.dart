// 本地 SLM 實機探針 —— Qwen2.5-1.5B q8 (.litertlm) on Android
//
// 本檔案由 Claude 於 2026-09-23 撰寫，供友達智慧座艙專案的「驗證一」使用。
//
// 目的：回答三個問題，不是做產品。
//   1. 1.6 GB 的 .litertlm 在這台機器上載得進去嗎？載多久？
//   2. TTFT（按下去到第一個字出現）幾秒？
//   3. decode 幾 tok/s？
//
// ⚠️ 版本限制（踩過才知道的，要寫進計畫）：
//   flutter_gemma 1.9.0 需要 Flutter >= 3.44 / Dart >= 3.12，
//   而本機是 Flutter 3.35.2 / Dart 3.9.0，裝不起來。
//   0.12.7 起引入 dart_sentencepiece_tokenizer（所有版本都要 Dart ^3.10.7）也裝不起來。
//   **0.12.6（2026-03-22）是最後一個相容版本，而且已支援 .litertlm。**
//
// 📁 模型位置：
//   /sdcard/Android/data/com.example.slm_probe/files/model.litertlm
//   選這裡是因為 App 讀自己的 external files dir **不需要任何權限**；
//   放 /sdcard/Download 在 Android 13+ 會需要 MANAGE_EXTERNAL_STORAGE。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';

// 🔴 flutter_gemma 必須在 runApp 之前初始化，否則 install() 會丟
//    "Bad state: FlutterGemma not initialized!"
//    （0.12.6 的 FlutterGemma.initialize() 內部呼叫 ServiceRegistry.initialize）
String? gInitError;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await FlutterGemma.initialize();
    // ignore: avoid_print
    print('[SLM_PROBE] ✅ FlutterGemma.initialize() 完成');
  } catch (e, st) {
    gInitError = '$e';
    // ignore: avoid_print
    print('[SLM_PROBE] 🔴 FlutterGemma.initialize() 失敗：$e');
    print('[SLM_PROBE] $st');
  }
  runApp(const SlmProbeApp());
}

class SlmProbeApp extends StatelessWidget {
  const SlmProbeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SLM 探針',
        theme: ThemeData.dark(useMaterial3: true),
        home: const ProbePage(),
      );
}

/// 與「驗證零」同一組題型，方便跟筆電的結果對照。
const List<(String, String)> kPrompts = [
  ('安全1 ≤8字', '狀態: co2=2600→ 車內=26 車外=31 循環=內 乘員=2 車速=90\n決策: 立即切換外循環 | 原因=CO2 2600 已達嗜睡風險\n緊急度: 安全 | 上限: 8字'),
  ('安全2 ≤8字', '狀態: co2=2600↓ 車內=22 車外=31 循環=內 乘員=4 車速=35\n決策: 立即切換外循環 | 原因=CO2 2600 已達嗜睡風險 | 代價=車內將升溫約4度\n緊急度: 安全 | 上限: 8字'),
  ('安全3 ≤8字', '狀態: co2=2600↓ 車內=18 車外=12 循環=內 乘員=2 車速=0\n決策: 立即切換外循環 | 原因=CO2 2600 已達嗜睡風險 | 代價=車內將降溫約3度\n緊急度: 安全 | 上限: 8字'),
  ('安全4 ≤8字', '狀態: co2=2600↑↑ 車內=30 車外=31 循環=內 乘員=1 車速=0\n決策: 立即切換外循環 | 原因=CO2 2600 已達嗜睡風險\n緊急度: 安全 | 上限: 8字'),
  ('主動5 ≤15字', '狀態: co2=1340↑ 車內=26 車外=38 循環=內 乘員=1 車速=90\n決策: 建議稍後換氣 | 原因=CO2 1340 上升中\n緊急度: 主動告知 | 上限: 15字'),
  ('主動6 ≤15字', '狀態: co2=1340↑↑ 車內=26 車外=24 循環=內 乘員=2 車速=110\n決策: 建議稍後換氣 | 原因=CO2 1340 上升中\n緊急度: 主動告知 | 上限: 15字'),
  ('主動7 ≤15字', '狀態: co2=1340↑ 車內=26 車外=31 循環=內 乘員=2 車速=110\n決策: 建議稍後換氣 | 原因=CO2 1340 上升中\n緊急度: 主動告知 | 上限: 15字'),
  ('主動8 ≤15字', '狀態: co2=1980→ 車內=26 車外=24 循環=內 乘員=2 車速=0\n決策: 切換外循環 | 原因=CO2 1980 偏高\n緊急度: 主動告知 | 上限: 15字'),
  ('沉默9 ≤0字', '狀態: co2=880→ 車內=34 車外=38 循環=內 乘員=1 車速=35\n決策: 維持現狀 | 原因=各項數值正常\n緊急度: 不說話 | 上限: 0字'),
  ('沉默10 ≤0字', '狀態: co2=2600↓ 車內=22 車外=24 循環=外 乘員=1 車速=35\n決策: 維持現狀 | 原因=已經是外循環\n緊急度: 不說話 | 上限: 0字'),
  ('沉默11 ≤0字', '狀態: co2=880↑↑ 車內=34 車外=12 循環=外 乘員=1 車速=0\n決策: 維持現狀 | 原因=各項數值正常\n緊急度: 不說話 | 上限: 0字'),
  ('沉默12 ≤0字', '狀態: co2=420→ 車內=18 車外=38 循環=內 乘員=4 車速=0\n決策: 維持現狀 | 原因=各項數值正常\n緊急度: 不說話 | 上限: 0字'),
];

/// 設 true 則 App 一開就自動載入模型並跑完全部題目，結果寫進 results.md。
const bool kAutoRun = true;

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
class ProbePage extends StatefulWidget {
  const ProbePage({super.key});
  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  final List<String> _log = [];
  final TextEditingController _input =
      TextEditingController(text: kPrompts.first.$2);

  InferenceModel? _model;
  bool _busy = false;
  String _status = '尚未載入';
  PreferredBackend _backend = PreferredBackend.cpu;
  final int _maxTokens = 2048;

  Duration? _loadTime;
  Duration? _ttft;
  double? _decodeTokPerSec;
  Duration? _totalTime;
  String? _lastDiag;
  String _currentLabel = '(手動)';
  final List<Map<String, dynamic>> _results = [];

  void _say(String s) {
    // ignore: avoid_print
    print('[SLM_PROBE] $s');
    if (!mounted) return;
    setState(() => _log.insert(0, s));
  }

  Future<String> _modelPath() async {
    final Directory? d = await getExternalStorageDirectory();
    if (d == null) throw Exception('取不到 external files dir');
    return '${d.path}/model.litertlm';
  }

  /// 用 SAF 檔案選取器把 .litertlm 匯入 App 專屬目錄。
  ///
  /// Android 11 起檔案管理員進不去 /sdcard/Android/data/<pkg>/files，
  /// 所以不能叫使用者自己把檔案放過去。SAF 不需要任何權限。
  Future<void> _importModel() async {
    if (_busy) return;
    setState(() { _busy = true; _status = '選擇模型檔…'; });
    IOSink? sink;
    try {
      final res = await FilePicker.platform.pickFiles(
        withReadStream: true,           // 1.6 GB，不要整個讀進記憶體
        allowMultiple: false,
      );
      if (res == null || res.files.isEmpty) {
        _say('已取消');
        setState(() { _busy = false; _status = '未匯入模型'; });
        return;
      }
      final f = res.files.first;
      final total = f.size;
      _say('── 匯入 ${f.name}（${(total / 1e9).toStringAsFixed(2)} GB）');

      final dst = File(await _modelPath());
      if (await dst.exists()) await dst.delete();
      sink = dst.openWrite();
      int done = 0, lastPct = -1;
      await for (final chunk in f.readStream!) {
        sink.add(chunk);
        done += chunk.length;
        final pct = total > 0 ? (done * 100 ~/ total) : 0;
        if (pct != lastPct && pct % 5 == 0) {
          lastPct = pct;
          _say('   複製 $pct%');
          if (mounted) setState(() => _status = '複製模型 $pct%');
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final len = await dst.length();
      _say('✅ 匯入完成，$len bytes');
      if (len != total) {
        _say('⚠️ 大小與來源不符（來源 $total），建議重新匯入');
      }
      setState(() { _busy = false; });
      await _checkModel();
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      _say('🔴 匯入失敗：$e');
      if (mounted) setState(() { _busy = false; _status = '匯入失敗'; });
    }
  }

  /// 把 results.md 的內容複製到剪貼簿（零依賴，最不會出錯的一條路）。
  Future<void> _copyResults() async {
    try {
      final Directory? d = await getExternalStorageDirectory();
      if (d == null) return;
      final f = File('${d.path}/results.md');
      if (!await f.exists()) {
        _say('⚠️ 還沒有 results.md，先跑完測試');
        return;
      }
      final txt = await f.readAsString();
      await Clipboard.setData(ClipboardData(text: txt));
      _say('📋 已複製 ${txt.length} 字到剪貼簿，直接貼到 LINE 傳回即可');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已複製到剪貼簿，貼到 LINE 傳回即可')),
        );
      }
    } catch (e) {
      _say('⚠️ 複製失敗：$e');
    }
  }

  /// 另存一份到使用者選的位置（例如「下載」），方便用檔案方式傳。
  Future<void> _saveResults() async {
    try {
      final Directory? d = await getExternalStorageDirectory();
      if (d == null) return;
      final f = File('${d.path}/results.md');
      if (!await f.exists()) {
        _say('⚠️ 還沒有 results.md，先跑完測試');
        return;
      }
      final bytes = await f.readAsBytes();
      final path = await FilePicker.platform.saveFile(
        fileName: 'results_tabS9.md',
        bytes: bytes,
      );
      _say(path == null ? '已取消' : '💾 已另存：$path');
    } catch (e) {
      _say('⚠️ 另存失敗：$e');
    }
  }

  Future<void> _checkModel() async {
    try {
      final p = await _modelPath();
      final f = File(p);
      if (await f.exists()) {
        final len = await f.length();
        _say('✅ 找到模型：$p');
        _say('   大小 $len bytes (${(len / 1e9).toStringAsFixed(3)} GB)');
        setState(() => _status = '模型就位，可載入');
      } else {
        _say('❌ 找不到模型。請用 adb 推到：');
        _say('   $p');
        setState(() => _status = '缺模型');
      }
    } catch (e) {
      _say('❌ 檢查失敗：$e');
    }
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '載入中…';
    });
    final sw = Stopwatch()..start();
    try {
      if (gInitError != null) {
        throw StateError('FlutterGemma 未初始化：$gInitError');
      }
      final p = await _modelPath();
      _say('── 開始載入 (backend=${_backend.name}, maxTokens=$_maxTokens) ──');

      await FlutterGemma.installModel(
        modelType: ModelType.qwen,
        // 0.12.6 的列舉註解逐字：task 涵蓋 .task 與 .litertlm
        fileType: ModelFileType.task,
      ).fromFile(p).withProgress((int pct) {
        if (pct % 20 == 0) _say('   安裝 $pct%');
      }).install();

      _say('   install() 完成 ${sw.elapsed.inSeconds}s，建立 model…');

      final m = await FlutterGemma.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: _backend,
      );
      sw.stop();
      _model = m;
      _loadTime = sw.elapsed;
      _say('✅ 載入完成，耗時 ${sw.elapsed.inMilliseconds / 1000}s');
      setState(() => _status = '已載入 (${_backend.name})');
    } catch (e, st) {
      sw.stop();
      _say('🔴 載入失敗 (${sw.elapsed.inSeconds}s)：$e');
      _say('   $st');
      setState(() => _status = '載入失敗');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(String prompt) async {
    final m = _model;
    if (m == null) {
      _say('⚠️ 先載入模型');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _ttft = null;
      _decodeTokPerSec = null;
      _totalTime = null;
    });

    InferenceModelSession? session;
    try {
      _say('── 提問：$prompt');
      session = await m.createSession(temperature: 0.2, randomSeed: 42, topK: 1);

      final String full = '$kSystemPrompt\n\n$prompt';
      await session.addQueryChunk(Message.text(text: full, isUser: true));

      // 🔬 診斷：先問引擎「這段 prompt 是幾個 token」。
      //    如果回報的 token 數跟字數明顯不成比例，代表 sizeInTokens() 不可信，
      //    那由它算出的 decode tok/s 也不可信。
      int promptTokens = -1;
      try {
        promptTokens = await session.sizeInTokens(full);
      } catch (e) {
        _say('   ⚠️ sizeInTokens(prompt) 失敗：$e');
      }

      final sw = Stopwatch()..start();
      Duration? first;
      final buf = StringBuffer();
      int chunks = 0;

      await for (final String piece in session.getResponseAsync()) {
        first ??= sw.elapsed;
        buf.write(piece);
        chunks++;
      }
      sw.stop();

      final String out = buf.toString().trim();

      int apiTokens = -1;
      try {
        apiTokens = await session.sizeInTokens(out);
      } catch (e) {
        _say('   ⚠️ sizeInTokens(output) 失敗：$e');
      }

      final int chars = out.runes.length;
      final int cjk = RegExp(r'[一-鿿]').allMatches(out).length;

      final double decodeSecs =
          (sw.elapsed - (first ?? Duration.zero)).inMilliseconds / 1000.0;

      // 三種算法並列，讓人判斷哪個可信：
      //   A. 引擎回報的 token 數
      //   B. 串流塊數（引擎若一次吐一個 token 就等於 A；吐一整句就會遠小於）
      //   C. 字數（Qwen 的中文約 1 字 ≈ 0.7–1 token，是保守上界）
      double? rate(int n) => (decodeSecs > 0 && n > 0) ? n / decodeSecs : null;
      final rApi = rate(apiTokens);
      final rChunk = rate(chunks);
      final rChar = rate(chars);

      setState(() {
        _ttft = first;
        _totalTime = sw.elapsed;
        // 主數字改用字數估算，因為 sizeInTokens 疑似低報
        _decodeTokPerSec = rChar;
        _lastDiag = 'API $apiTokens ／ 塊 $chunks ／ 字 $chars';
      });

      _say('💬 $out');
      _say('   TTFT ${(first?.inMilliseconds ?? 0) / 1000}s'
          '  總計 ${sw.elapsed.inMilliseconds / 1000}s'
          '  decode 期間 ${decodeSecs.toStringAsFixed(2)}s');
      _say('   🔬 prompt ${full.runes.length} 字 → 引擎說 $promptTokens token'
          '${promptTokens > 0 ? "（${(full.runes.length / promptTokens).toStringAsFixed(2)} 字/token）" : ""}');
      _say('   🔬 output $chars 字（中文 $cjk）'
          ' ／ 串流 $chunks 塊 ／ 引擎說 $apiTokens token');
      _say('   📊 decode：by引擎 ${rApi?.toStringAsFixed(1) ?? "?"}'
          ' ｜ by塊 ${rChunk?.toStringAsFixed(1) ?? "?"}'
          ' ｜ by字 ${rChar?.toStringAsFixed(1) ?? "?"} tok/s');

      _results.add(<String, dynamic>{
        'label': _currentLabel,
        'backend': _backend.name,
        'prompt': prompt,
        'output': out,
        'ttft_s': (first?.inMilliseconds ?? 0) / 1000.0,
        'total_s': sw.elapsed.inMilliseconds / 1000.0,
        'decode_s': decodeSecs,
        'prompt_chars': full.runes.length,
        'prompt_tokens_api': promptTokens,
        'out_chars': chars,
        'out_cjk': cjk,
        'out_chunks': chunks,
        'out_tokens_api': apiTokens,
        'rate_by_api': rApi,
        'rate_by_chunk': rChunk,
        'rate_by_char': rChar,
      });
      await _writeResults();
    } catch (e) {
      _say('🔴 生成失敗：$e');
    } finally {
      await session?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runAll() async {
    for (final (label, p) in kPrompts) {
      if (!mounted) return;
      _currentLabel = label;
      _say('══════ $label ══════');
      await _run(p);
    }
    _currentLabel = '(手動)';
    _say('══════ 全部跑完 ══════');
    await _writeResults();
  }

  /// 把所有結果寫成 Markdown，放在 App 的 external files dir。
  ///
  /// 這樣可以用 adb 直接抓，不必截圖：
  ///   adb pull /sdcard/Android/data/com.example.slm_probe/files/results.md
  Future<void> _writeResults() async {
    if (_results.isEmpty) return;
    try {
      final Directory? d = await getExternalStorageDirectory();
      if (d == null) return;
      final f = File('${d.path}/results.md');

      final b = StringBuffer()
        ..writeln('# 本地 SLM 實機量測結果')
        ..writeln()
        ..writeln('- 產生時間：${DateTime.now()}')
        ..writeln('- 模型：Qwen2.5-1.5B q8 `.litertlm`（1,597,931,520 bytes）')
        ..writeln('- 引擎：flutter_gemma 0.12.6')
        ..writeln('- 載入耗時：${_loadTime?.inMilliseconds != null ? _loadTime!.inMilliseconds / 1000 : "?"} s')
        ..writeln()
        ..writeln('## 摘要')
        ..writeln()
        ..writeln('| 題目 | backend | TTFT(s) | 總計(s) | decode(s) | 輸出字數 |'
            ' 引擎token | 串流塊 | by引擎 | by塊 | by字 |')
        ..writeln('|---|---|---|---|---|---|---|---|---|---|---|');

      String n(dynamic v, [int d = 1]) =>
          v == null ? '—' : (v is num ? v.toStringAsFixed(d) : '$v');

      for (final r in _results) {
        b.writeln('| ${r['label']} | ${r['backend']} | ${n(r['ttft_s'], 2)} |'
            ' ${n(r['total_s'], 2)} | ${n(r['decode_s'], 2)} | ${r['out_chars']} |'
            ' ${r['out_tokens_api']} | ${r['out_chunks']} |'
            ' ${n(r['rate_by_api'])} | ${n(r['rate_by_chunk'])} |'
            ' ${n(r['rate_by_char'])} |');
      }

      b
        ..writeln()
        ..writeln('## 逐題內容')
        ..writeln();
      for (final r in _results) {
        b
          ..writeln('### ${r['label']}（${r['backend']}）')
          ..writeln()
          ..writeln('**提問**：${r['prompt']}')
          ..writeln()
          ..writeln('**回答**：${r['output']}')
          ..writeln()
          ..writeln('- prompt ${r['prompt_chars']} 字 → 引擎說'
              ' ${r['prompt_tokens_api']} token')
          ..writeln('- output ${r['out_chars']} 字（中文 ${r['out_cjk']}）／'
              '串流 ${r['out_chunks']} 塊／引擎說 ${r['out_tokens_api']} token')
          ..writeln();
      }

      await f.writeAsString(b.toString());
      _say('📄 已寫入 ${f.path}');
    } catch (e) {
      _say('⚠️ 寫結果檔失敗：$e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (gInitError != null) {
        _say('🔴 FlutterGemma 初始化失敗：$gInitError');
        setState(() => _status = '初始化失敗');
      } else {
        _say('✅ FlutterGemma 已初始化');
      }
      _checkModel().then((_) async {
        if (!kAutoRun) return;
        if (!mounted || _model != null || _busy) return;
        if (!await File(await _modelPath()).exists()) {
          _say('ℹ️ 尚未匯入模型。請按「① 匯入模型檔」選擇 .litertlm。');
          return;
        }
        _say('🤖 自動載入並開跑');
        await _load();
        if (!mounted || _model == null) return;
        await _runAll();
        _say('✅ 全部完成，請按「③ 複製結果」，貼到 LINE 傳回。');
      });
    });
  }

  @override
  void dispose() {
    _model?.close();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地 SLM 探針 · Qwen2.5-1.5B q8'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_status,
                  style: const TextStyle(fontSize: 13, color: Colors.amber)),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.black26,
            child: Wrap(spacing: 18, runSpacing: 6, children: [
              _metric('載入',
                  _loadTime == null ? '—' : '${_loadTime!.inMilliseconds / 1000}s'),
              _metric('TTFT',
                  _ttft == null ? '—' : '${_ttft!.inMilliseconds / 1000}s'),
              _metric(
                  'decode(by字)',
                  _decodeTokPerSec == null
                      ? '—'
                      : '${_decodeTokPerSec!.toStringAsFixed(1)} tok/s'),
              _metric('總計',
                  _totalTime == null ? '—' : '${_totalTime!.inMilliseconds / 1000}s'),
              if (_lastDiag != null) _metric('🔬 計數', _lastDiag!),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
              DropdownButton<PreferredBackend>(
                value: _backend,
                onChanged: _busy || _model != null
                    ? null
                    : (v) => setState(() => _backend = v!),
                items: const [
                  DropdownMenuItem(
                      value: PreferredBackend.cpu, child: Text('CPU')),
                  DropdownMenuItem(
                      value: PreferredBackend.gpu, child: Text('GPU')),
                ],
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: _busy ? null : _importModel,
                child: const Text('① 匯入模型檔'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy || _model != null ? null : _load,
                child: const Text('② 載入'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy || _model == null ? null : _runAll,
                child: const Text('跑全部'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _copyResults,
                icon: const Icon(Icons.copy_all, size: 18),
                label: const Text('③ 複製結果'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _saveResults,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('或存成檔案'),
              ),
            ])),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder()),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed:
                    _busy || _model == null ? null : () => _run(_input.text),
              ),
            ]),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final (label, p) in kPrompts)
                ActionChip(
                  label: Text(label, style: const TextStyle(fontSize: 11)),
                  onPressed: _busy ? null : () => _input.text = p,
                ),
            ],
          ),
          const Divider(height: 12),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText(_log[i],
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace', height: 1.35)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(k, style: const TextStyle(fontSize: 11, color: Colors.white54)),
          Text(v,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ],
      );
}
