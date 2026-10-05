// 儀表端（手機）—— 連中控的 WebSocket，收事件
//
// 位址來源：①UDP :8766 自動發現 ②手動輸入（記在 App 目錄，下次自動帶入）
// 斷線自動重連；超過 3 秒沒收到任何事件就把狀態燈打成 down（INTERFACE.md §7）
// —— 這條是儀表自己判斷的，中控掛了就不會告訴任何人。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'hub.dart' show kBeaconPort, kBeaconTag, kWsPort;
import 'protocol.dart';

class Link extends ChangeNotifier {
  Link._();
  static final Link I = Link._();

  String? host;
  bool connected = false;
  Envelope? last;
  DateTime? lastAt;
  bool badSchema = false; // 收到不認得的格式 → 降級、不顯示內容（§9）
  final Set<String> discovered = {};
  final Set<String> _seen = {};

  WebSocket? _ws;
  Timer? _retry, _watch;
  RawDatagramSocket? _udp;
  bool _running = false;

  /// 逾時判斷：超過 3 秒沒收到 → down
  bool get stale =>
      lastAt == null || DateTime.now().difference(lastAt!).inMilliseconds > 3000;

  Avail get lamp {
    if (stale) return Avail.down;
    if (badSchema) return Avail.degraded;
    return last?.availability ?? Avail.down;
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    host ??= await _loadHost();
    _listenBeacon();
    _watch = Timer.periodic(const Duration(milliseconds: 500), (_) => notifyListeners());
    if (host != null) _connect();
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _watch?.cancel();
    _udp?.close();
    _udp = null;
    await _ws?.close();
    _ws = null;
    connected = false;
  }

  Future<void> useHost(String h) async {
    host = h.trim();
    await _saveHost(host!);
    await _ws?.close();
    _ws = null;
    _connect();
    notifyListeners();
  }

  void _connect() {
    _retry?.cancel();
    final h = host;
    if (h == null || h.isEmpty || !_running) return;
    WebSocket.connect('ws://$h:$kWsPort')
        .timeout(const Duration(seconds: 3))
        .then((ws) {
      _ws = ws;
      connected = true;
      notifyListeners();
      ws.listen(_onMsg, onDone: _lost, onError: (_) => _lost());
    }).catchError((Object _) {
      _lost();
    });
  }

  void _lost() {
    connected = false;
    _ws = null;
    notifyListeners();
    if (_running) {
      _retry = Timer(const Duration(seconds: 2), _connect);
    }
  }

  void _onMsg(dynamic data) {
    lastAt = DateTime.now();
    Object? j;
    try {
      j = jsonDecode('$data');
    } catch (_) {
      badSchema = true;
      return notifyListeners();
    }
    final e = Envelope.fromJson(j);
    if (e == null) {
      badSchema = true;
      return notifyListeners();
    }
    badSchema = false;
    if (!_seen.add(e.eventId)) return; // event_id 去重
    if (_seen.length > 500) _seen.remove(_seen.first);
    last = e;
    notifyListeners();
  }

  Future<void> _listenBeacon() async {
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kBeaconPort,
          reuseAddress: true);
      _udp!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = _udp?.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true);
        if (!msg.startsWith(kBeaconTag)) return;
        final ip = dg.address.address;
        if (discovered.add(ip)) notifyListeners();
        // 還沒設過位址、或記住的位址連不上（換了網路），就改用廣播找到的中控
        if (host == null || (!connected && host != ip)) useHost(ip);
      });
    } catch (_) {
      // 有些手機收不到 UDP 廣播（需 multicast lock）—— 手動輸入 IP 一樣能用
    }
  }

  Future<File> _hostFile() async {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}/hub_host.txt');
  }

  Future<String?> _loadHost() async {
    try {
      final f = await _hostFile();
      if (await f.exists()) {
        final s = (await f.readAsString()).trim();
        return s.isEmpty ? null : s;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveHost(String h) async {
    try {
      await (await _hostFile()).writeAsString(h);
    } catch (_) {}
  }
}
