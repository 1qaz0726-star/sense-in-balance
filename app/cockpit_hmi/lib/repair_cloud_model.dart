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
      // 不送 X-Title：避免 App 名稱出現在 OpenRouter 公開排行。
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.add(
        utf8.encode(
          jsonEncode({
            'model': model,
            'temperature': 0,
            'max_tokens': 256,
            // 零資料留存、不拿去訓練；關掉推理，避免推理 token 吃光 max_tokens。
            'provider': {'zdr': true, 'data_collection': 'deny'},
            'reasoning': {'enabled': false},
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
          (jsonDecode(body)
                  as Map<String, dynamic>)['choices'][0]['message']['content']
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
  final match = RegExp(
    r'^```(?:json)?\s*([\s\S]*?)\s*```$',
  ).firstMatch(trimmed);
  return match == null ? trimmed : match.group(1)!;
}

/// 主動探測：真的打一次雲端（金鑰查詢端點，約 0.1–0.2 秒），不只查 DNS。
/// 只查 DNS 可能被快取騙到；這裡 2 秒內拿到 200 才算連得上。
Future<bool> cloudReachable({String apiKey = kOpenRouterKey}) async {
  if (apiKey.isEmpty) return false;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .getUrl(Uri.parse('https://openrouter.ai/api/v1/key'))
        .timeout(const Duration(seconds: 2));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    final response = await request.close().timeout(const Duration(seconds: 2));
    await response.drain<void>();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 連續兩次探測失敗才判定離線，避免一次掉包就讓狀態燈閃爍。
class CloudLink {
  CloudLink({Future<bool> Function()? probe})
    : _probe = probe ?? cloudReachable;
  final Future<bool> Function() _probe;
  bool online = false;
  int _failures = 0;

  /// 回傳狀態是否改變。
  Future<bool> check() async {
    final ok = await _probe();
    final before = online;
    if (ok) {
      _failures = 0;
      online = true;
    } else if (++_failures >= 2) {
      online = false;
    }
    return online != before;
  }
}

CloudAssist? cloudAssistFromEnvironment({
  void Function(Map<String, dynamic> lesson)? onLesson,
  CloudLink? link,
}) {
  if (kOpenRouterKey.isEmpty) return null;
  final model = OpenRouterModel(apiKey: kOpenRouterKey);
  return CloudAssist(
    generate: model.generate,
    isOnline: () async => link?.online ?? await cloudReachable(),
    onLesson: onLesson,
  );
}

const kCloudKnowledgePrompt = '''你是車內語音助理的雲端增強，只在本地知識庫查不到時被呼叫。
用繁體中文、台灣用語，30 個字以內，只回一句話，不要條列、不要表情符號。
可以回答一般常識或旅途相關問題。
如果問的是這台車的功能、儀表警示燈、故障、保養或維修，一律只回答：這題請查車主手冊或洽原廠。
不知道或沒把握就回答：這題我沒把握，建議停車後再查。''';

/// 本地知識庫查不到時的雲端回答；離線、沒金鑰、逾時或不合格都回 null（照舊說查不到）。
Future<String?> cloudKnowledgeAnswer(
  String question, {
  String apiKey = kOpenRouterKey,
}) async {
  if (apiKey.isEmpty) return null;
  try {
    final raw = await OpenRouterModel(apiKey: apiKey)
        .generate(kCloudKnowledgePrompt, question)
        .timeout(const Duration(seconds: 6));
    final text = raw.trim();
    // 超過長度就當不合格，不截短（截短可能改變意思）。
    if (text.isEmpty || text.runes.length > 40 || text.contains('\n')) {
      return null;
    }
    return text;
  } catch (_) {
    return null;
  }
}
