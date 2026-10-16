// Hybrid AI 雲端增強：連網時把「沒點名項目」的句子交給雲端模型解讀（OpenRouter）。
//
// 金鑰只從建置參數讀：flutter build apk --dart-define=OPENROUTER_API_KEY=...
// 帶金鑰的 APK 只裝在自己的展示裝置，不上傳公開 repo／release。
// 沒有金鑰時 cloudAssistFromEnvironment() 回 null，App 行為與純離線版相同。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'repair_parser.dart';

const kOpenRouterKey = String.fromEnvironment('OPENROUTER_API_KEY');
const kCloudModel = String.fromEnvironment(
  'CLOUD_MODEL',
  defaultValue: 'google/gemini-3.1-flash-lite',
);

class OpenRouterModel {
  OpenRouterModel({
    required this.apiKey,
    this.model = kCloudModel,
    this.endpoint = 'https://openrouter.ai/api/v1/chat/completions',
  });
  final String apiKey;
  final String model;
  final String endpoint;

  Future<String> generate(String system, String prompt) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.postUrl(Uri.parse(endpoint));
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..set('X-Title', 'Sense in Balance cockpit demo');
      request.add(
        utf8.encode(
          jsonEncode({
            'model': model,
            'temperature': 0,
            'max_tokens': 256,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': prompt},
            ],
          }),
        ),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException('雲端回應 ${response.statusCode}');
      }
      final content =
          (jsonDecode(body) as Map<String, dynamic>)['choices'][0]['message']['content']
              as String;
      return stripCodeFence(content);
    } finally {
      client.close(force: true);
    }
  }
}

/// 雲端模型偶爾把 JSON 包在 ```json 區塊裡；只剝掉外層圍欄，內容仍交給嚴格解析。
String stripCodeFence(String content) {
  final trimmed = content.trim();
  final match = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(trimmed);
  return match == null ? trimmed : match.group(1)!;
}

/// 連得上雲端端點才算「連網」；1.2 秒內查不到就當離線。
Future<bool> cloudReachable() async {
  try {
    final r = await InternetAddress.lookup(
      'openrouter.ai',
    ).timeout(const Duration(milliseconds: 1200));
    return r.isNotEmpty;
  } catch (_) {
    return false;
  }
}

CloudAssist? cloudAssistFromEnvironment({
  void Function(Map<String, dynamic> lesson)? onLesson,
}) {
  if (kOpenRouterKey.isEmpty) return null;
  final model = OpenRouterModel(apiKey: kOpenRouterKey);
  return CloudAssist(
    generate: model.generate,
    isOnline: cloudReachable,
    onLesson: onLesson,
  );
}
