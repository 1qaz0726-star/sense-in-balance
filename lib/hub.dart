// 中控內建的 AI Box —— 2026-10-05 決定：原本規劃放筆電的角色整個搬進平板 App
//
//   情境注入（L1）→ 模擬車輛訊號 → 規則引擎 → 措辭（SLM／模板／知識庫）
//        → 每秒一則事件 → 本機中控畫面 ＋ WebSocket :8765 廣播給儀表（手機）
//
// 心跳 1 秒（INTERFACE.md §8）：沒事也發 silent，接收端才分得出「不用講」和「掛了」。
// 另外每 2 秒在 UDP :8766 廣播自己的位址，儀表端可以自動找到，不用手打 IP。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'guard.dart';
import 'kb.dart';
import 'protocol.dart';
import 'rules.dart';
import 'slm.dart';

const int kWsPort = 8765;
const int kBeaconPort = 8766;
const String kBeaconTag = 'COCKPIT_HUB';

/// 情境 —— 對應影片腳本 A–D（研究/八天衝刺計畫_報名影片_20260929.md §四）
enum Scene { normal, co2Rising, recircOut, parked }

/// 一句話的措辭結果，跟著 decision.key 走：數值在變、動作沒變，就不重講
class _Utterance {
  final String key;
  String? text;
  String? src; // slm／template／kb／rule
  int? ms;
  String? rejected; // 模型輸出被 guard 擋下的原因
  String? rawModel;
  bool spoken = false;
  _Utterance(this.key);
}

class Hub extends ChangeNotifier {
  Hub._();
  static final Hub I = Hub._();

  // ─── 模擬車輛狀態（取代 CAN） ───
  double co2 = 420;
  final List<double> _co2Hist = [];
  // 車外 34 度：自動切外循環時車內會升溫 → 有代價 → 才需要告知駕駛
  int tIn = 26, tOut = 34, occ = 2;
  double fuel = 62; // %
  String? _turnSide;
  DateTime? _turnUntil;
  Decision? _inform;
  DateTime? _informUntil;
  String recirc = '內';
  int speed = 45;
  double _spd = 45; // 連續值；對外只發整數
  int _t = 0;
  Scene scene = Scene.normal;

  // ─── 暫態事件 ───
  DateTime? _blindStart, _blindUntil;
  String _blindSide = 'right', _blindObj = '機車';
  DateTime? _replyUntil;
  Map<String, dynamic>? _queryState;
  Decision? _queryDecision;
  _Utterance? _queryUtt;

  // ─── 輸出 ───
  final _out = StreamController<Envelope>.broadcast();
  Stream<Envelope> get events => _out.stream;
  Envelope? last;
  final List<String> log = []; // 中控控制面板看的紀錄

  int _seq = 0;
  _Utterance? _utt;
  Timer? _tick;
  HttpServer? _server;
  final Set<WebSocket> _clients = {};
  RawDatagramSocket? _beacon;
  Timer? _beaconTimer;
  List<String> myIps = [];
  int get clientCount => _clients.length;
  String? serverError;

  /// 句子定案時呼叫一次（中控接到語音；測試環境不接）。urgent＝安全級
  void Function(String text, bool urgent)? onSpeak;

  bool get running => _tick != null;

  Future<void> start() async {
    if (running) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _step());
    _step();
    await _startServer();
    await _startBeacon();
    notifyListeners();
  }

  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    _beaconTimer?.cancel();
    _beacon?.close();
    _beacon = null;
    for (final c in _clients.toList()) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, kWsPort);
      serverError = null;
      _server!.listen((req) async {
        if (!WebSocketTransformer.isUpgradeRequest(req)) {
          req.response
            ..statusCode = 200
            ..write('cockpit hub ok, clients=${_clients.length}');
          await req.response.close();
          return;
        }
        final ws = await WebSocketTransformer.upgrade(req);
        _clients.add(ws);
        _note('儀表連上（${req.connectionInfo?.remoteAddress.address}）');
        if (last != null) ws.add(jsonEncode(last!.toJson()));
        ws.listen((_) {}, onDone: () {
          _clients.remove(ws);
          _note('儀表斷線');
        }, onError: (_) => _clients.remove(ws));
      });
    } catch (e) {
      serverError = '$e';
    }
    myIps = await localIps();
  }

  Future<void> _startBeacon() async {
    try {
      _beacon = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _beacon!.broadcastEnabled = true;
      _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        myIps = await localIps();
        final msg = utf8.encode('$kBeaconTag $kWsPort');
        try {
          _beacon?.send(msg, InternetAddress('255.255.255.255'), kBeaconPort);
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _note(String s) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    log.insert(0, '${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $s');
    if (log.length > 60) log.removeLast();
    notifyListeners();
  }

  // ─── 情境注入（L1） ───────────────────────────────────────

  void setScene(Scene s) {
    scene = s;
    switch (s) {
      case Scene.normal:
        co2 = 420;
        _co2Hist.clear();
        recirc = '內';
      case Scene.co2Rising:
        if (co2 < 700) co2 = 700; // 先升一段（約 6 秒）才過 800 的門檻
        recirc = '內';
      case Scene.recircOut:
        recirc = '外';
      case Scene.parked:
        break;
    }
    _note('情境 → ${sceneName(s)}');
    _step(sim: false);
  }

  void injectBlindSpot({String side = 'right', String object = '機車', int seconds = 4}) {
    _blindSide = side;
    _blindObj = object;
    // 典型情境：駕駛打方向燈準備變換車道 → 該側後方有來車
    final now = DateTime.now();
    _turnSide = side;
    _turnUntil = now.add(Duration(seconds: seconds + 1));
    _blindStart = now.add(const Duration(seconds: 1));
    _blindUntil = _blindStart!.add(Duration(seconds: seconds));
    Timer(const Duration(seconds: 1), () => _step(sim: false));
    _note('注入：打${sideZh(side)}方向燈，${sideZh(side)}後方$object');
    _step(sim: false);
  }

  /// 駕駛提問。只在停車時接受（道安規則 §90：行駛中不得操作行車輔助顯示設備）
  Future<void> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) return;
    final online = await hasInternet();
    final (answer, hit) = lookup(q);
    _queryState = {'question': q, 'online': online, 'speed': speed};
    _queryDecision = Decision(
      action: answer,
      urgency: Urgency.reply,
      reason: hit ? '本地知識庫檢索' : '本地知識庫查無資料',
    );
    _queryUtt = _Utterance(_queryDecision!.key)
      ..text = answer
      ..src = 'kb';
    _replyUntil = DateTime.now().add(const Duration(seconds: 12));
    _note('提問「$q」→ ${hit ? '知識庫命中' : '查無資料'}（${online ? '有網路' : '離線'}）');
    _step(sim: false);
  }

  void dismissReply() {
    _replyUntil = null;
    _step(sim: false);
  }

  // ─── 每秒一步 ─────────────────────────────────────────────

  void _simulate() {
    final rnd = Random();
    // 車速：行駛時在 40–60 之間緩慢起伏（像市區巡航），停車時每秒減 12 到 0
    _t++;
    if (scene == Scene.parked) {
      _spd = max(0, _spd - 12);
    } else {
      final target = 50 + 9 * sin(_t / 9) + rnd.nextDouble() * 2 - 1;
      final step = (target - _spd).clamp(-4.0, 4.0);
      _spd += step;
    }
    speed = _spd.round();
    fuel = max(5, fuel - 0.02);
    switch (scene) {
      case Scene.normal:
        co2 = 420 + rnd.nextDouble() * 20;
      case Scene.co2Rising:
        // 系統一旦自動切到外循環，CO₂ 就會降下來
        co2 = recirc == '內'
            ? min(co2 + 14 + rnd.nextDouble() * 4, 2400)
            : max(co2 - 45, 600);
      case Scene.recircOut:
        co2 = max(co2 - 45, 600);
      case Scene.parked:
        break;
    }
    _co2Hist.add(co2);
    if (_co2Hist.length > 4) _co2Hist.removeAt(0);
  }

  String _trend() {
    if (_co2Hist.length < 2) return '→';
    final perSec = (_co2Hist.last - _co2Hist.first) / (_co2Hist.length - 1);
    if (perSec > 30) return '↑↑';
    if (perSec > 5) return '↑';
    if (perSec < -5) return '↓';
    return '→';
  }

  Map<String, dynamic> cabinState() {
    final c = co2.round();
    final tr = _trend();
    return {
      'co2': c,
      'co2_label': co2Label(c),
      'trend': tr,
      'trend_label': kTrendLabel[tr],
      't_in': tIn,
      't_out': tOut,
      'recirc': recirc,
      'occ': occ,
      'speed': speed,
    };
  }

  /// sim=false：只重新廣播（措辭完成、情境切換時），不推進模擬時間
  void _step({bool sim = true}) {
    if (sim) _simulate();
    final now = DateTime.now();
    String domain;
    Map<String, dynamic> state;
    Decision d;
    _Utterance? u;

    // 優先序：安全 > 回答 > 座艙空氣
    if (_blindUntil != null && !now.isBefore(_blindStart!) && now.isBefore(_blindUntil!)) {
      domain = 'blind_spot';
      state = {
        'side': _blindSide,
        'object': _blindObj,
        'ttc_s': null,
        'speed': speed,
        'bbox': null,
        'confidence': null,
      };
      d = decideBlindSpot(state);
    } else if (_replyUntil != null && now.isBefore(_replyUntil!)) {
      domain = 'query';
      state = {..._queryState!, 'speed': speed};
      d = _queryDecision!;
      u = _queryUtt;
    } else {
      domain = 'cabin_air';
      state = cabinState();
      d = decideCabin(state);
      // 執行層：要換氣就系統自己切，不叫駕駛做（rules.dart informAuto）
      if (recirc == '內' && needsVentilation(d)) {
        recirc = '外';
        _inform = informAuto(d, state);
        _informUntil = now.add(const Duration(seconds: 8));
        _note('系統自動切外循環（${d.reason}）'
            '${_inform!.cost.isEmpty ? '，無感 → 不告知' : '，${_inform!.cost} → 告知'}');
      }
      if (_informUntil != null && now.isBefore(_informUntil!)) d = _inform!;
    }

    if (u == null) {
      if (_utt?.key != d.key) {
        _utt = _Utterance(d.key);
        _startPhrase(_utt!, domain, state, d);
      }
      u = _utt;
    }

    // 告知的 8 秒從「句子出來」才開始算：實機 SLM 措辭要 6–7 秒，不然句子只露臉一下就收掉
    if (_inform != null && identical(d, _inform) && u?.text == null) {
      _informUntil = now.add(const Duration(seconds: 8));
    }

    if (u != null && u.text != null && !u.spoken) {
      u.spoken = true;
      onSpeak?.call(u.text!, d.urgency == Urgency.safety);
    }

    final env = Envelope(
      eventId: 'evt_${(++_seq).toString().padLeft(6, '0')}',
      ts: now.millisecondsSinceEpoch / 1000.0,
      source: 'L1',
      domain: domain,
      state: state,
      decision: d,
      availability: Avail.ok,
      phrase: u?.text,
      phraseSrc: u?.src,
      phraseMs: u?.ms,
      vehicle: _vehicle(now),
    );
    last = env;
    _out.add(env);
    final js = jsonEncode(env.toJson());
    for (final c in _clients.toList()) {
      try {
        c.add(js);
      } catch (_) {
        _clients.remove(c);
      }
    }
    notifyListeners();
  }

  /// 決定這句話誰來講。安全級與模型未就緒走模板，其他交給 SLM，輸出過 guard 才用。
  void _startPhrase(_Utterance u, String domain, Map<String, dynamic> s, Decision d) {
    if (d.urgency == Urgency.silent) {
      u.text = null;
      u.src = 'rule';
      return;
    }
    final tpl = templatePhrase(domain, s, d);
    if (d.urgency == Urgency.safety || domain != 'cabin_air') {
      // 安全級不等模型：警示不能被 1–2 秒的生成延遲擋住，方位也不給模型改寫的機會
      u.text = tpl;
      u.src = 'rule';
      _note('安全級 → 規則直出「$tpl」');
      return;
    }
    if (!Slm.I.ready) {
      u.text = tpl;
      u.src = 'template';
      _note('模型未就緒 → 模板「$tpl」');
      return;
    }
    final prompt = renderPrompt(s, d);
    final sw = Stopwatch()..start();
    Slm.I.phrase(prompt).then((raw) {
      sw.stop();
      final g = check(raw, prompt, d);
      u.ms = sw.elapsedMilliseconds;
      u.rawModel = raw.trim();
      if (g.ok) {
        u.text = g.text;
        u.src = 'slm';
        _note('SLM ${u.ms} ms →「${g.text}」');
      } else {
        u.text = tpl;
        u.src = 'template';
        u.rejected = g.why;
        _note('SLM 輸出「${u.rawModel}」被擋（${g.why}）→ 模板「$tpl」');
      }
      if (_utt == u) _step(sim: false);
    }).catchError((e) {
      u.text = tpl;
      u.src = 'template';
      _note('SLM 失敗（$e）→ 模板');
      if (_utt == u) _step(sim: false);
    });
  }

  String? get lastRejected => _utt?.rejected;

  /// 儀表常駐：時速、檔位、油量、方向燈、警示燈（只放亮著的）
  Map<String, dynamic> _vehicle(DateTime now) {
    final turning = _turnUntil != null && now.isBefore(_turnUntil!);
    return {
      'speed': speed,
      'gear': scene == Scene.parked && speed == 0 ? 'P' : 'D',
      'fuel_pct': fuel.round(),
      'turn': turning ? _turnSide : null,
      'telltales': [if (fuel < 12) 'fuel_low'],
    };
  }
}

String sceneName(Scene s) => const {
      Scene.normal: 'A 一切正常',
      Scene.co2Rising: 'B CO₂ 上升',
      Scene.recircOut: '手動切外循環',
      Scene.parked: 'D 停車',
    }[s]!;

Future<List<String>> localIps() async {
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in ifs)
        for (final a in i.addresses)
          if (!a.isLoopback) a.address,
    ];
  } catch (_) {
    return [];
  }
}

Future<bool> hasInternet() async {
  try {
    final r = await InternetAddress.lookup('huggingface.co')
        .timeout(const Duration(milliseconds: 1200));
    return r.isNotEmpty;
  } catch (_) {
    return false;
  }
}
