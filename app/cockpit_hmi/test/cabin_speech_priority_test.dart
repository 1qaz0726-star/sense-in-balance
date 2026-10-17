import 'dart:async';

import 'package:cockpit_hmi/repair_speech.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  late Completer<List<Map<String, dynamic>>> voices;
  late List<String> calls;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    voices = Completer<List<Map<String, dynamic>>>();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getVoices') return voices.future;
          return 1;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  void completeVoices() => voices.complete([
    {
      'name': 'local',
      'locale': 'zh-TW',
      'network_required': '0',
      'features': '',
    },
  ]);

  test(
    'priority stop invalidates a result speech still awaiting voice lookup',
    () async {
      final feedback = RepairSpeechFeedback();
      final speech = feedback.speak('模擬調整完成');
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('getVoices'));
      await feedback.stop();
      completeVoices();
      expect(await speech, false);
      expect(calls, isNot(contains('speak')));
    },
  );

  test(
    'attention becoming blocked before final dispatch prevents stale narration',
    () async {
      final feedback = RepairSpeechFeedback();
      var allowed = true;
      final speech = feedback.speak('模擬調整完成', allowed: () => allowed);
      await Future<void>.delayed(Duration.zero);
      allowed = false;
      completeVoices();
      expect(await speech, false);
      expect(calls, isNot(contains('speak')));
    },
  );
}
