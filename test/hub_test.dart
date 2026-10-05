// 端到端：真的啟動 Hub（WebSocket :8765），用一個 WebSocket 用戶端當儀表收事件，
// 跑一遍影片的四個情境。測試環境沒有模型 → 主動告知會走模板，這也是要驗的保底路徑。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/hub.dart';
import 'package:cockpit_hmi/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('四個情境經 WebSocket 送到儀表端', () async {
    await Hub.I.start();
    final ws = await WebSocket.connect('ws://127.0.0.1:$kWsPort');
    final got = <Envelope>[];
    final sub = ws.listen((m) => got.add(Envelope.fromJson(jsonDecode(m))!));

    Future<Envelope> waitFor(bool Function(Envelope) f, {int secs = 8}) async {
      final end = DateTime.now().add(Duration(seconds: secs));
      while (DateTime.now().isBefore(end)) {
        final hit = got.reversed.where(f);
        if (hit.isNotEmpty) return hit.first;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      throw TimeoutException('等不到事件；最後一則：${got.isEmpty ? '無' : jsonEncode(got.last.toJson())}');
    }

    // 心跳：一秒一則、event_id 遞增
    await Future.delayed(const Duration(milliseconds: 2300));
    expect(got.length, greaterThanOrEqualTo(2));
    expect(got.map((e) => e.eventId).toSet().length, got.length);

    // A 一切正常 → silent，沒有句子
    Hub.I.setScene(Scene.normal);
    final a = await waitFor((e) => e.domain == 'cabin_air');
    expect(a.decision.urgency, Urgency.silent);
    expect(a.phrase, isNull);

    // B CO₂ 上升 → 系統自己切外循環（不叫駕駛做）；車外 34 度會升溫 → 有代價 → 告知
    Hub.I.setScene(Scene.co2Rising);
    final b = await waitFor((e) => e.decision.action == '已自動切換外循環');
    expect(b.decision.urgency, Urgency.proactive);
    expect(b.decision.cost, contains('升溫'));
    expect(b.phrase, '已換外循環，會稍熱');
    expect(b.phraseSrc, 'template');
    expect(Hub.I.recirc, '外');

    // 告知 8 秒後回到 silent，CO₂ 下降
    final r = await waitFor(
        (e) => e.domain == 'cabin_air' && e.decision.urgency == Urgency.silent && e.ts > b.ts + 8,
        secs: 12);
    expect(r.state['trend'], '↓');

    // C 盲點 → 安全級、規則直出，4 秒後自動結束
    Hub.I.injectBlindSpot(seconds: 2);
    final c = await waitFor((e) => e.domain == 'blind_spot');
    expect(c.decision.urgency, Urgency.safety);
    expect(c.phrase, '右後方有機車');
    expect(c.phraseSrc, 'rule');
    expect(c.vehicle?['turn'], 'right'); // 先打方向燈才偵測到
    await waitFor((e) => e.domain == 'cabin_air' && e.ts > c.ts + 2);

    // D 停車問答：查得到、查不到
    Hub.I.setScene(Scene.parked);
    final p = await waitFor((e) => e.speed == 0 && e.vehicle?['gear'] == 'P');
    expect(p.vehicle?['fuel_pct'], isA<int>());
    await Hub.I.ask('為什麼要換氣？');
    final d1 = await waitFor((e) => e.domain == 'query');
    expect(d1.decision.urgency, Urgency.reply);
    expect(d1.phraseSrc, 'kb');
    expect(d1.phrase, isNot(contains('查不到')));
    await Hub.I.ask('冷氣濾網多久換一次？');
    final d2 = await waitFor((e) =>
        e.domain == 'query' && e.state['question'] == '冷氣濾網多久換一次？');
    expect(d2.phrase, '這個我查不到，請參考車主手冊');

    await sub.cancel();
    await ws.close();
    await Hub.I.stop();
  }, timeout: const Timeout(Duration(seconds: 90)));
}
