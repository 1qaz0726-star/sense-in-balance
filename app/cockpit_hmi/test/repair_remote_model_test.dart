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
      expect(model.detail, contains('指定模型'));
      expect(model.detail, contains('Qwen2.5-1.5B-Instruct'));
    },
  );

  test(
    'sends real system/user messages and preserves UTF-8 model output',
    () async {
      await model.boot();
      expect(model.ready, isTrue);
      expect(model.model, kRepairModelId);
      expect(model.status, contains('Qwen2.5-1.5B-Instruct'));
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
    'V3 preserves trained one-user contract without constrained JSON decoding',
    () async {
      model.dispose();
      model = RemoteRepairModel(
        Uri.parse('http://127.0.0.1:${server.port}'),
        model: 'cabin-v3-clean-hybrid',
        singleUserPrompt: true,
      );
      handler = (request) {
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'cabin-v3-clean-hybrid'},
            ],
          }),
        );
        request.response.close();
      };
      await model.boot();
      expect(model.ready, true);
      Map<String, dynamic>? payload;
      handler = (request) async {
        payload = jsonDecode(await utf8.decoder.bind(request).join());
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'content':
                      '{"changes":{"mediaVolume":"decrease"},"clarification":null}',
                },
              },
            ],
          }),
        );
        request.response.close();
      };
      await model.generate('修正規則', '{"user_text":"音樂小聲一點"}');
      expect(payload!['messages'], [
        {'role': 'user', 'content': '修正規則\n\n{"user_text":"音樂小聲一點"}'},
      ]);
      expect(payload!.containsKey('response_format'), false);
      expect(payload!['model'], 'cabin-v3-clean-hybrid');
      expect(payload!['temperature'], 0);
    },
  );

  test(
    'trained model alias is checked and sent without quantization claims',
    () async {
      model.dispose();
      model = RemoteRepairModel(
        Uri.parse('http://127.0.0.1:${server.port}'),
        model: 'Qwen2.5-1.5B-Cabin-v1',
      );
      handler = (request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/v1/models');
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'Qwen2.5-1.5B-Instruct'},
              {'id': 'Qwen2.5-1.5B-Cabin-v1'},
            ],
          }),
        );
        request.response.close();
      };
      await model.boot();
      expect(model.ready, isTrue);
      expect(model.status, contains('Qwen2.5-1.5B-Cabin-v1'));
      expect(model.status, isNot(contains('Q8')));

      Map<String, dynamic>? payload;
      handler = (request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/v1/chat/completions');
        payload = jsonDecode(await utf8.decoder.bind(request).join());
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': '{"changes":{},"clarification":null}'},
              },
            ],
          }),
        );
        request.response.close();
      };
      await model.generate('規則', '風量先不用改');
      expect(payload!['model'], 'Qwen2.5-1.5B-Cabin-v1');
    },
  );

  test('trained model never falls back to an available base model', () async {
    model.dispose();
    model = RemoteRepairModel(
      Uri.parse('http://127.0.0.1:${server.port}'),
      model: 'Qwen2.5-1.5B-Cabin-v1',
    );
    await model.boot();
    expect(model.ready, isFalse);
    expect(model.detail, contains('Qwen2.5-1.5B-Cabin-v1'));
    expect(model.generate('規則', '風量先不用改'), throwsStateError);
  });

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
