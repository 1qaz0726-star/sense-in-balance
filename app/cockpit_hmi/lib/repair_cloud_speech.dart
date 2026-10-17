// Hybrid AI 雲端增強：連網時的語音辨識。錄音送到自家 Cloudflare Worker（sib-asr），
// Worker 同時跑台語（Breeze-ASR-26）與華語（Whisper），挑出像車內需求的那一段。
// 金鑰都在 Worker；App 只帶通行碼。沒有建置參數時為 null，App 維持純離線語音。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const kSibAsrUrl = String.fromEnvironment('SIB_ASR_URL');
const kSibAsrToken = String.fromEnvironment('SIB_ASR_TOKEN');

class CloudTranscript {
  CloudTranscript({required this.text, required this.lang, this.timingMs});
  final String text;

  /// 'nan'＝採用台語模型的結果；'zh'＝採用華語模型的結果（不是語言偵測，是哪個模型的輸出被選中）。
  final String lang;
  final int? timingMs;
}

/// 台語辨識還在叫醒、而華語結果不通順：不給錯的文字，請乘客幾秒後再說一次。
class TaigiWarming implements Exception {
  const TaigiWarming();
}

class CloudSpeech {
  CloudSpeech({required this.url, required this.token});
  final String url;
  final String token;

  static CloudSpeech? fromEnvironment() =>
      kSibAsrUrl.isEmpty || kSibAsrToken.isEmpty
      ? null
      : CloudSpeech(url: kSibAsrUrl, token: kSibAsrToken);

  Future<HttpClientResponse> _post(
    String path,
    List<int> body,
    Duration timeout,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final request = await client
        .postUrl(Uri.parse('$url$path'))
        .timeout(timeout);
    request.headers
      ..set('x-sib-token', token)
      ..contentType = ContentType.binary;
    request.add(body);
    return request.close().timeout(timeout);
  }

  Future<CloudTranscript> transcribe(Uint8List audio) async {
    final response = await _post('/asr', audio, const Duration(seconds: 14));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException('雲端辨識失敗（${response.statusCode}）');
    }
    final data = jsonDecode(body) as Map<String, dynamic>;
    if (data['error'] == 'taigi_warming') throw const TaigiWarming();
    final text = '${data['text'] ?? ''}'.trim();
    if (data['ok'] != true || text.isEmpty || text.runes.length > 500) {
      throw const FormatException('雲端辨識沒有結果');
    }
    return CloudTranscript(
      text: text,
      lang: '${data['lang']}',
      timingMs: (data['timing_ms'] as Map?)?['total'] as int?,
    );
  }

  /// 把 RunPod 叫醒（冷啟動約 40 秒）；不等結果，失敗也不影響使用。
  Future<void> warm() async {
    try {
      final response = await _post(
        '/warm',
        const [],
        const Duration(seconds: 8),
      );
      await response.drain<void>();
    } catch (_) {}
  }
}
