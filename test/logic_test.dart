// 邏輯測試：規則引擎與 states.py 逐筆一致、guard 擋得住實測抓過的錯、知識庫不亂配
//
// states_golden.json 由 研究/蒸餾工具/states.py 窮舉 12,000 組狀態產生。

import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/guard.dart';
import 'package:cockpit_hmi/kb.dart';
import 'package:cockpit_hmi/protocol.dart';
import 'package:cockpit_hmi/rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('規則引擎與 states.py 的 12,000 組決策、提示詞逐字一致', () {
    final rows = jsonDecode(File('test/states_golden.json').readAsStringSync())
        as List;
    var n = 0;
    for (final r in rows) {
      final py = r['s'] as Map;
      final s = <String, dynamic>{
        'co2': int.parse(py['co2']),
        'trend': py['trend'],
        't_in': int.parse(py['t_in']),
        't_out': int.parse(py['t_out']),
        'recirc': py['recirc'],
        'occ': int.parse(py['occ']),
        'speed': int.parse(py['speed']),
      };
      final d = decideCabin(s);
      final want = r['d'] as Map;
      expect(d.action, want['action'], reason: '$py');
      expect(d.urgency.name, want['urgency'], reason: '$py');
      expect(d.reason, want['reason'], reason: '$py');
      expect(d.cost, want['cost'], reason: '$py');
      expect(renderPrompt(s, d), r['p'], reason: '$py');
      n++;
    }
    expect(n, 12000);
  });

  group('guard', () {
    const calm = Decision(
        action: '建議稍後換氣', urgency: Urgency.proactive, reason: 'CO2 1340 上升中');
    const p = '狀態: co2=1340↑ 車內=26 車外=31 循環=內 乘員=2 車速=110\n'
        '決策: 建議稍後換氣 | 原因=CO2 1340 上升中\n緊急度: 主動告知 | 上限: 15字';

    test('正常輸出通過', () {
      expect(check('二氧化碳在升，等下記得換氣', p, calm).ok, isTrue);
    });
    test('09-30 平板實測抓到的「會影響健康」要被擋', () {
      final g = check('快切換外循環，CO2偏高會影響健康', p, calm);
      expect(g.ok, isFalse);
    });
    test('建議級出現催促詞要被擋', () {
      expect(check('快換氣', p, calm).ok, isFalse);
    });
    test('編造數字要被擋', () {
      expect(check('二氧化碳 2000 了要換氣', p, calm).ok, isFalse);
    });
    test('超字數要被擋（不算標點）', () {
      expect(check('二氧化碳正在慢慢上升，等一下記得要換氣喔', p, calm).ok, isFalse);
    });
    test('簡體字要被擋', () {
      expect(check('二氧化碳在升，等下记得换气', p, calm).ok, isFalse);
    });
    test('該沉默就要 <silent>', () {
      const sil = Decision(action: '維持現狀', urgency: Urgency.silent);
      expect(check('<silent>', p, sil).ok, isTrue);
      expect(check('一切正常', p, sil).ok, isFalse);
    });
  });

  group('知識庫', () {
    test('命中', () {
      expect(lookup('為什麼要換氣？').$2, isTrue);
      expect(lookup('胎壓燈亮了').$2, isTrue);
      expect(lookup('沒有網路還能用嗎？').$2, isTrue);
    });
    test('查不到就說查不到，不亂配', () {
      expect(lookup('冷氣濾網多久換一次？'), (kNotFound, false));
      expect(lookup('燈亮了怎麼辦').$2, isFalse);
      expect(lookup('雨刷怎麼調').$2, isFalse);
    });
    test('每一則答案都在 30 字內', () {
      for (final e in kKb) {
        expect(body(e.a).runes.length, lessThanOrEqualTo(30), reason: e.a);
      }
    });
  });

  test('模板措辭都在字數上限內', () {
    for (final a in ['立即切換外循環', '切換外循環', '建議稍後換氣']) {
      final u = a.startsWith('立即') ? Urgency.safety : Urgency.proactive;
      final t = templatePhrase('cabin_air', {}, Decision(action: a, urgency: u));
      expect(body(t).runes.length, lessThanOrEqualTo(u.limit), reason: t);
    }
    final s = {'side': 'right', 'object': '自行車'};
    final t = templatePhrase('blind_spot', s, decideBlindSpot(s));
    expect(t, '右後方有自行車');
    expect(body(t).runes.length, lessThanOrEqualTo(8));
  });

  test('信封可以來回序列化；不認得的 schema 回傳 null', () {
    final e = Envelope(
      eventId: 'evt_000001',
      ts: 1.5,
      source: 'L1',
      domain: 'cabin_air',
      state: const {'co2': 420, 'speed': 45},
      decision: const Decision(action: '維持現狀', urgency: Urgency.silent),
      phrase: 'x',
      phraseSrc: 'slm',
    );
    final back = Envelope.fromJson(jsonDecode(jsonEncode(e.toJson())))!;
    expect(back.decision.key, e.decision.key);
    expect(back.speed, 45);
    expect(back.phrase, 'x');
    expect(Envelope.fromJson({...e.toJson(), 'schema': '2.0'}), isNull);
    expect(Envelope.fromJson({...e.toJson(), 'domain': 'lane_departure'}), isNull);
  });
}
