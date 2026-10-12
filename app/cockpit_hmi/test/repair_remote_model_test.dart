import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cockpit_hmi/repair_remote_model.dart';

void main() {
  late HttpServer server;
  late RemoteRepairModel model;
  late void Function(HttpRequest) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (request) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {'id': 'Qwen2.5-1.5B-Instruct'},
          ],
        }),
      );
      request.response.close();
    };
    server.listen((request) => handler(request));
    model = RemoteRepairModel(Uri.parse('http://127.0.0.1:${server.port}'));
  });

  tearDown(() async {
    model.dispose();
    await server.close(force: true);
  });

  test(
    'preflight requires the requested model, never substitutes another',
    () async {
      handler = (request) {
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'unrelated-model'},
            ],
          }),
        );
        request.response.close();
      };
      await model.boot();
      expect(model.ready, isFalse);
      expect(model.detail, contains('指定的 Qwen'));
    },
  );

  test(
    'sends real system/user messages and preserves UTF-8 model output',
    () async {
      await model.boot();
      expect(model.ready, isTrue);
      Map<String, dynamic>? payload;
      handler = (request) async {
        payload = jsonDecode(await utf8.decoder.bind(request).join());
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'content': '{"changes":{},"clarification":"哪個音量？"}',
                },
              },
            ],
          }),
        );
        request.response.close();
      };
      final result = await model.generate('規則', '使用者原話');
      expect(payload!['messages'], [
        {'role': 'system', 'content': '規則'},
        {'role': 'user', 'content': '使用者原話'},
      ]);
      expect(payload!['model'], 'Qwen2.5-1.5B-Instruct');
      expect(result, contains('哪個音量'));
      expect(model.lastElapsedMs, isNotNull);
    },
  );

  test(
    'rejects truncated generation instead of treating it as an action',
    () async {
      await model.boot();
      handler = (request) {
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'length',
                'message': {'content': '{"changes":{'},
              },
            ],
          }),
        );
        request.response.close();
      };
      expect(model.generate('規則', '音樂小一點'), throwsFormatException);
    },
  );
}
