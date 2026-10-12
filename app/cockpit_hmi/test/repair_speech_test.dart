import 'package:cockpit_hmi/repair_speech.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RepairSpeechInput.channel, null);
  });

  test('離線ASR不存在時不呼叫recognize或雲端替代', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RepairSpeechInput.channel, (call) async {
          calls.add(call.method);
          return false;
        });
    final input = RepairSpeechInput();
    await expectLater(input.listen(), throwsA(isA<PlatformException>()));
    expect(calls, ['available']);
    input.dispose();
  });

  test('只接受已標示端上且完整的文字結果，不自動送出車控', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RepairSpeechInput.channel, (call) async {
          if (call.method == 'available') return true;
          expect(call.arguments, {'language': 'zh-TW'});
          return {'text': '  風量先不要改  ', 'on_device': true};
        });
    final input = RepairSpeechInput();
    expect(await input.listen(), '風量先不要改');
    input.dispose();
  });

  test('不把未證明端上或空白結果交給模型', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RepairSpeechInput.channel, (call) async {
          if (call.method == 'available') return true;
          return {'text': '音量降低', 'on_device': false};
        });
    final input = RepairSpeechInput();
    await expectLater(input.listen(), throwsFormatException);
    input.dispose();
  });
}
