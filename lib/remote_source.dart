// 遠端 AI Box：iPad（或任何瀏覽器）開網頁版中控，連手機上的 Hub
//   ws://<手機>:8765/center —— 收事件＋狀態，送情境／提問指令回去
// 模型、語音、規則都在手機上跑；這邊只負責顯示與操作。

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'center_source.dart';
import 'protocol.dart';

class RemoteSource extends CenterSource {
  RemoteSource(this.url);
  final Uri url;

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _retry, _watch;
  bool _running = false;
  bool connected = false;
  final _out = StreamController<Envelope>.broadcast();
  Envelope? _last;
  DateTime? _lastAt;
  Map<String, dynamic> _st = const {};

  @override
  Future<void> start() async {
    _running = true;
    _watch = Timer.periodic(const Duration(milliseconds: 500), (_) => notifyListeners());
    _connect();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _watch?.cancel();
    await _sub?.cancel();
    await _ch?.sink.close();
  }

  Future<void> _connect() async {
    if (!_running) return;
    try {
      final ch = WebSocketChannel.connect(url);
      await ch.ready.timeout(const Duration(seconds: 4));
      _ch = ch;
      connected = true;
      notifyListeners();
      _sub = ch.stream.listen(_onMsg, onDone: _lost, onError: (_) => _lost());
    } catch (_) {
      _lost();
    }
  }

  void _lost() {
    connected = false;
    _ch = null;
    notifyListeners();
    if (_running) {
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 2), _connect);
    }
  }

  void _onMsg(dynamic m) {
    Object? j;
    try {
      j = jsonDecode('$m');
    } catch (_) {
      return;
    }
    if (j is Map && j['type'] == 'status') {
      _st = Map<String, dynamic>.from(j);
      notifyListeners();
      return;
    }
    final e = Envelope.fromJson(j);
    if (e == null) return;
    _last = e;
    _lastAt = DateTime.now();
    _out.add(e);
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  bool get _stale =>
      _lastAt == null || DateTime.now().difference(_lastAt!).inMilliseconds > 3000;

  @override
  Stream<Envelope> get events => _out.stream;
  @override
  Envelope? get last => _last;
  @override
  Avail get lamp => _stale ? Avail.down : (_last?.availability ?? Avail.down);
  @override
  String? get hint => _last == null
      ? '正在連線 AI Box（${url.host}）…'
      : (_stale ? '與 AI Box 斷線，重試中…' : null);

  @override
  void setScene(Scene s) => _send({'cmd': 'scene', 'scene': s.name});
  @override
  void injectBlindSpot({String side = 'right', String object = '機車', int seconds = 4}) =>
      _send({'cmd': 'blind', 'side': side, 'object': object, 'seconds': seconds});
  @override
  void ask(String q) => _send({'cmd': 'ask', 'q': q});
  @override
  void dismissReply() => _send({'cmd': 'dismiss'});

  @override
  List<String> get log => [for (final l in (_st['log'] as List? ?? const [])) '$l'];
  @override
  String get modelText => '${_st['model'] ?? '（等待 AI Box 回報）'}';
  @override
  String get voiceText => '${_st['voice'] ?? ''}（語音從 AI Box 那台發出）';
  @override
  bool get voiceOn => _st['voice_on'] != false;
  @override
  void setVoice(bool on) => _send({'cmd': 'voice', 'on': on});
  @override
  String get connText => connected
      ? 'AI Box：${url.host}:${url.port}・儀表 ${_st['dash'] ?? '?'} 台'
      : '連不上 AI Box（${url.host}:${url.port}），每 2 秒重試';
}
