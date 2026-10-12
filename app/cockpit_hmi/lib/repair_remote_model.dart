// Desktop demonstration only: real Qwen on this PC, called by the Android AVD.
// Leaving REPAIR_MODEL_URL unset keeps the original on-device LiteRT backend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const kRepairModelUrl = String.fromEnvironment('REPAIR_MODEL_URL');

class RemoteRepairModel extends ChangeNotifier {
  RemoteRepairModel(
    this.base, {
    this.model = 'Qwen2.5-1.5B-Instruct',
    this.timeout = const Duration(seconds: 28),
  });

  final Uri base;
  final String model;
  final Duration timeout;
  final HttpClient _client = HttpClient();
  bool ready = false;
  bool _disposed = false;
  String detail = '正在連接電腦上的 Qwen 1.5B…';
  int? lastElapsedMs;

  String get status => ready
      ? '真實 Qwen 2.5 1.5B · 電腦本地推論（GGUF Q8）'
            '${lastElapsedMs == null ? '' : ' · 上次 ${(lastElapsedMs! / 1000).toStringAsFixed(1)} 秒'}'
      : detail;

  Future<void> boot() async {
    try {
      final data = await _json('/v1/models');
      final models = data['data'];
      if (models is! List || !models.any((e) => e is Map && e['id'] == model)) {
        throw const FormatException('主機未載入指定的 Qwen 1.5B');
      }
      if (_disposed) return;
      ready = true;
      detail = '';
    } catch (e) {
      if (_disposed) return;
      ready = false;
      detail = '電腦模型尚未就緒：$e';
    }
    if (!_disposed) notifyListeners();
  }

  Future<String> generate(String system, String prompt) async {
    if (!ready) throw StateError('電腦上的 Qwen 尚未就緒');
    final watch = Stopwatch()..start();
    final data = await _json('/v1/chat/completions', {
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': prompt},
      ],
      'stream': false,
      'temperature': 0,
      'seed': 42,
      'max_tokens': 256,
      'response_format': {'type': 'json_object'},
    });
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException('模型回應缺少 choices');
    }
    final choice = choices.first as Map;
    if (choice['finish_reason'] != 'stop') {
      throw const FormatException('模型回應未完整結束');
    }
    final message = choice['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.isEmpty) {
      throw const FormatException('模型回應不是文字');
    }
    lastElapsedMs = watch.elapsedMilliseconds;
    if (!_disposed) notifyListeners();
    return content;
  }

  Future<Map<String, dynamic>> _json(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    HttpClientRequest? request;
    try {
      return await (() async {
        request = body == null
            ? await _client.getUrl(base.resolve(path))
            : await _client.postUrl(base.resolve(path));
        if (body != null) {
          request!.headers.contentType = ContentType.json;
          request!.write(jsonEncode(body));
        }
        final response = await request!.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 65536) {
            throw const FormatException('模型回應過大');
          }
        }
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('模型主機 HTTP ${response.statusCode}');
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('模型回應不是 JSON object');
        }
        return decoded;
      })().timeout(timeout);
    } catch (_) {
      request?.abort();
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close(force: true);
    super.dispose();
  }
}
