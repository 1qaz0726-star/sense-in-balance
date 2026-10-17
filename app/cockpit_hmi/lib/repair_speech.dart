import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Input only: a transcript must be reviewed and explicitly submitted.
/// Android's strict on-device recognizer is used; availability is device and
/// installed language-pack dependent. The emulator is not proof of S9 ASR.
class RepairSpeechInput {
  static const channel = MethodChannel('sense_in_balance/repair_speech');
  bool _disposed = false;
  bool _busy = false;

  Future<bool> isAvailable() async {
    if (_disposed ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    return await channel.invokeMethod<bool>('available') ?? false;
  }

  Future<String?> listen({String language = 'zh-TW'}) async {
    if (_disposed) return null;
    if (_busy) throw StateError('語音輸入仍在進行。');
    _busy = true;
    try {
      if (!await isAvailable()) {
        throw PlatformException(
          code: 'unavailable',
          message: '此裝置尚未準備離線語音，請先輸入文字。',
        );
      }
      if (_disposed) return null;
      final result = await channel.invokeMapMethod<String, dynamic>(
        'recognize',
        {'language': language},
      );
      if (_disposed || result == null) return null;
      final text = result['text'];
      if (result['on_device'] != true ||
          text is! String ||
          text.trim().isEmpty ||
          text.runes.length > 500) {
        throw const FormatException('語音結果無法使用，請核對後輸入文字。');
      }
      return text.trim();
    } finally {
      _busy = false;
    }
  }

  /// Android 13+：查繁中離線語言包，沒裝就請系統下載。回傳 installed／downloading／unsupported／unavailable。
  Future<String> prepareLanguage({String language = 'zh-TW'}) async {
    if (_disposed ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return 'unavailable';
    }
    final result = await channel.invokeMapMethod<String, dynamic>(
      'prepareLanguage',
      {'language': language},
    );
    return '${result?['status'] ?? 'unavailable'}';
  }

  /// 連網時的雲端辨識用：錄一段 16kHz 單聲道 AAC，第二次呼叫 [stopRecording] 取回位元組。
  Future<void> startRecording() async {
    if (_busy) throw StateError('語音輸入仍在進行。');
    _busy = true;
    try {
      await channel.invokeMethod<bool>('recordStart');
    } catch (_) {
      _busy = false;
      rethrow;
    }
  }

  Future<Uint8List> stopRecording() async {
    try {
      final bytes = await channel.invokeMethod<Uint8List>('recordStop');
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('錄音是空的，請再說一次。');
      }
      return bytes;
    } finally {
      _busy = false;
    }
  }

  Future<void> cancel() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await channel.invokeMethod<void>('cancel');
    }
  }

  void dispose() {
    _disposed = true;
    if (_busy) cancel().catchError((Object _) {});
  }
}

/// Optional deterministic short result, using only voices advertised as local
/// by Android. No model-generated narration and no automatic repeated speech.
class RepairSpeechFeedback {
  final FlutterTts _tts = FlutterTts();
  int _generation = 0;

  Future<bool> speak(String text, {bool Function()? allowed}) async {
    final generation = ++_generation;
    bool current() => generation == _generation && (allowed?.call() ?? true);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    if (text.trim().isEmpty || text.runes.length > 100 || !current()) {
      return false;
    }
    final voices = await _tts.getVoices;
    if (!current() || voices is! List) return false;
    final available = voices.whereType<Map>().where(
      (voice) =>
          '${voice['locale']}'.replaceAll('_', '-').toLowerCase() == 'zh-tw' &&
          '${voice['network_required']}' == '0' &&
          !'${voice['features']}'.contains('notInstalled'),
    );
    if (available.isEmpty) return false;
    final voice = available.first;
    await _tts.setVoice({
      'name': '${voice['name']}',
      'locale': '${voice['locale']}',
    });
    if (!current()) return false;
    await _tts.setSpeechRate(0.48);
    if (!current()) return false;
    return await _tts.speak(text.trim()) == 1;
  }

  Future<void> stop() async {
    ++_generation;
    await _tts.stop();
  }
}
