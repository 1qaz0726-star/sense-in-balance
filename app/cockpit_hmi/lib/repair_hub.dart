import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'repair_task.dart';
import 'repair_collaboration.dart';
import 'cabin_driver_monitor_source.dart';
import 'repair_collaboration_widgets.dart' show driverOneLineSummary;
import 'cabin_policy.dart';

/// Read-only by default. With an explicit collaboration layer, one paired
/// driver may grant edits and confirm this passenger's current task.
class RepairHub {
  RepairHub(
    this.controller, {
    required this.modelStatus,
    required this.asset,
    this.cabinState,
    this.cockpitEvent,
    this.cockpitSignals,
    this.collaboration,
    this.listenPort = port,
  });
  final RepairController controller;
  final String Function() modelStatus;
  final Future<List<int>?> Function(String) asset;
  final Map<String, int> Function()? cabinState;
  final Map<String, dynamic>? Function()? cockpitEvent;
  final Listenable? cockpitSignals;
  final RepairCollaboration? collaboration;
  final int listenPort;
  int? get boundPort => _server?.port;
  HttpServer? _server;
  Timer? _heartbeat;
  int _generation = 0;
  final _clients = <WebSocket>{};
  final _peers = <WebSocket, _RepairPeer>{};
  CabinDriverMonitorSource? _driverMonitor;
  void Function(Object)? _previousExpiryHandler;
  void Function(Object)? _expiryHandler;
  List<String> addresses = [];
  static const port = 8767;

  Map<String, dynamic> status({Object? peer}) {
    final policy = collaboration?.policy;
    policy?.refresh();
    final state = cabinState?.call();
    return {
      'type': 'repair_status',
      'schema': policy == null ? 1 : 2,
      'at': DateTime.now().millisecondsSinceEpoch,
      'model': modelStatus(),
      'mode': '文字輸入／車控模擬',
      if (state != null)
        'cabin_state': {
          for (final entry in state.entries)
            entry.key:
                policy == null ||
                    policy.profile.readable.any((s) => s.name == entry.key)
                ? entry.value
                : null,
        },
      if (policy != null) 'cabin_context': policy.toJson(),
      if (cockpitEvent != null) 'cockpit_event': cockpitEvent!(),
      'task': controller.snapshot.toJson(),
      if (collaboration != null)
        'role': peer != null && collaboration!.isDriver(peer)
            ? 'driver'
            : 'observer',
      if (collaboration != null) 'collaboration': collaboration!.toJson(),
    };
  }

  Future<void> start() async {
    if (_server != null) return;
    final generation = ++_generation;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
    if (generation != _generation) {
      await server.close(force: true);
      return;
    }
    _server = server;
    try {
      addresses = [
        for (final i in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        ))
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      ];
    } catch (_) {
      if (identical(_server, server)) _server = null;
      await server.close(force: true);
      rethrow;
    }
    if (generation != _generation) return;
    controller.addListener(_broadcast);
    cockpitSignals?.addListener(_broadcast);
    collaboration?.addListener(_broadcast);
    if (collaboration != null) {
      _previousExpiryHandler = collaboration!.onDriverExpired;
      _expiryHandler = (peer) {
        if (peer is WebSocket) {
          _remove(peer);
          unawaited(peer.close());
        }
        _previousExpiryHandler?.call(peer);
      };
      collaboration!.onDriverExpired = _expiryHandler;
    }
    _heartbeat = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _broadcast(),
    );
    server.listen((request) async {
      if (generation != _generation || _server == null) {
        await request.response.close();
        return;
      }
      if (request.uri.path == '/repair' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        if (generation != _generation || _server == null) {
          await socket.close();
          return;
        }
        _clients.add(socket);
        _peers[socket] = _RepairPeer();
        socket.add(jsonEncode(status(peer: socket)));
        socket.listen(
          (message) {
            if (collaboration != null && generation == _generation) {
              _command(socket, message);
            }
          },
          onDone: () => _remove(socket),
          onError: (_) => _remove(socket),
        );
        return;
      }
      final parts = request.uri.pathSegments;
      final path = parts.isEmpty ? 'index.html' : parts.join('/');
      final response = request.response;
      if (parts.any((p) => p == '..' || p.contains('\\'))) {
        response.statusCode = 400;
      } else {
        final bytes = await asset(path);
        if (bytes == null) {
          response.statusCode = 404;
          response.write('請先建置並打包 repair 網頁；見 docs/DEVELOPMENT.md。');
        } else {
          final ext = path.split('.').last;
          response.headers.contentType = switch (ext) {
            'html' => ContentType.html,
            'js' => ContentType('application', 'javascript'),
            'json' => ContentType.json,
            'css' => ContentType('text', 'css'),
            'wasm' => ContentType('application', 'wasm'),
            'png' => ContentType('image', 'png'),
            _ => ContentType.binary,
          };
          response.add(bytes);
        }
      }
      await response.close();
    });
  }

  void _broadcast() {
    if (_server == null) return;
    collaboration?.checkTimeouts();
    for (final c in [..._clients]) {
      try {
        c.add(jsonEncode(status(peer: c)));
      } catch (_) {
        _remove(c);
      }
    }
  }

  Future<void> stop() async {
    ++_generation; // A pending start must not revive a disposed screen.
    controller.removeListener(_broadcast);
    cockpitSignals?.removeListener(_broadcast);
    collaboration?.removeListener(_broadcast);
    if (collaboration != null &&
        identical(collaboration!.onDriverExpired, _expiryHandler)) {
      collaboration!.onDriverExpired = _previousExpiryHandler;
    }
    _heartbeat?.cancel();
    _heartbeat = null;
    final server = _server;
    _server = null;
    for (final c in [..._clients]) {
      _remove(c);
      await c.close();
    }
    _clients.clear();
    _peers.clear();
    await server?.close(force: true);
  }

  void _remove(WebSocket socket) {
    _clients.remove(socket);
    _peers.remove(socket);
    collaboration?.disconnectDriver(socket);
  }

  void _command(WebSocket socket, Object? raw) {
    final peer = _peers[socket];
    final c = collaboration;
    if (peer == null || c == null) return;
    String? id;
    Map<String, dynamic> reply(bool accepted, String? error) => {
      'type': 'repair_reply',
      'command_id': id,
      'accepted': accepted,
      'error': error,
    };
    void send(Map<String, dynamic> message) {
      if (!_clients.contains(socket)) return;
      try {
        socket.add(jsonEncode(message));
      } catch (_) {
        _remove(socket);
      }
    }

    try {
      if (raw is! String || raw.length > 8192) {
        throw const FormatException('指令格式或長度不合法。');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('指令須為 JSON object。');
      }
      if (decoded['command_id'] is String &&
          (decoded['command_id'] as String).isNotEmpty &&
          (decoded['command_id'] as String).length <= 80) {
        id = decoded['command_id'] as String;
      }
      final keys = <String>{};
      for (final match in RegExp(r'"((?:[^"\\]|\\.)*)"\s*:').allMatches(raw)) {
        final key = jsonDecode('"${match.group(1)}"') as String;
        if (!keys.add(key)) throw const FormatException('指令不得有重複欄位。');
      }
      final action = decoded['action'];
      final policy = c.policy;
      if (action == 'driver_request') {
        // 駕駛自己說的需求：解析、能直接確認就直接執行（走同一個 confirm）。
        // 非同步完成後才回覆，回覆附上結果與一句話摘要給駕駛端念出。
        final text = decoded['text'];
        final sessionId = decoded['cabin_session_id'];
        if (id == null ||
            decoded['type'] != 'repair_command' ||
            decoded.length != (policy == null ? 4 : 5) ||
            text is! String ||
            (policy != null && sessionId is! String)) {
          throw const FormatException('不支援的指令或欄位。');
        }
        final commandId = id;
        unawaited(
          c
              .driverRequest(
                socket,
                text,
                sessionId: sessionId is String ? sessionId : null,
              )
              .then((outcome) {
                final task = controller.snapshot;
                send({
                  ...reply(outcome != 'rejected', c.error),
                  'command_id': commandId,
                  'outcome': outcome,
                  'summary': driverOneLineSummary(
                    {
                      for (final e in task.pending.entries)
                        e.key.name: e.value.name,
                    },
                    policy == null
                        ? const {}
                        : {
                            for (final e in policy.unsupported.entries)
                              e.key.name: e.value,
                          },
                  ),
                  if (task.clarification != null)
                    'clarification': task.clarification,
                });
                _broadcast();
              }),
        );
        return;
      }
      if (action == 'driver_monitor') {
        // 駕駛端鏡頭每 250 ms 一筆：只收已配對駕駛、同一工作階段；不回覆也不進指令快取。
        // 不合格就靜默丟棄，監測訊號過期時注意力規則本來就不會鎖住系統。
        final sessionId = decoded['cabin_session_id'];
        if (policy != null &&
            id != null &&
            decoded['type'] == 'repair_command' &&
            decoded.length == 5 &&
            decoded.containsKey('monitor') &&
            sessionId is String &&
            policy.matchesSession(sessionId) &&
            c.isDriver(socket)) {
          if (_driverMonitor?.policy != policy) {
            _driverMonitor = CabinDriverMonitorSource(policy);
          }
          _driverMonitor!.sample(decoded['monitor']);
        }
        return;
      }
      final taskAction = const {
        'grant',
        'revoke',
        'confirm',
        'resume_confirm',
        'cancel',
      }.contains(action);
      final allowed = <String>{
        'type',
        'command_id',
        'action',
        if (policy != null) 'cabin_session_id',
        if (action == 'pair_driver') 'pairing_code',
        if (taskAction) ...[
          'task_id',
          'revision',
          if (policy != null) ...[
            'profile_id',
            'profile_revision',
            'attention_epoch',
          ],
        ],
      };
      if (id == null ||
          decoded['type'] != 'repair_command' ||
          decoded.keys.any((key) => !allowed.contains(key)) ||
          decoded.length != allowed.length ||
          !const {
            'pair_driver',
            'heartbeat',
            'grant',
            'revoke',
            'confirm',
            'resume_confirm',
            'cancel',
          }.contains(action)) {
        throw const FormatException('不支援的指令或欄位。');
      }
      CabinContextIdentity? context;
      final sessionId = decoded['cabin_session_id'];
      if (policy != null) {
        policy.refresh();
        if (sessionId is! String || sessionId != policy.sessionId) {
          throw const FormatException('座艙工作階段已更換，請重新配對。');
        }
        if (taskAction) {
          context = CabinContextIdentity.fromJson({
            'cabin_session_id': sessionId,
            'profile_id': decoded['profile_id'],
            'profile_revision': decoded['profile_revision'],
            'attention_epoch': decoded['attention_epoch'],
          });
          if (context == null || !policy.matches(context)) {
            throw const FormatException('模式或車型狀態已更新，請查看最新摘要。');
          }
        }
      } else if (action == 'resume_confirm') {
        throw const FormatException('本工作階段未啟用模式續辦。');
      }
      final canonical = Map.fromEntries(
        decoded.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      );
      final fingerprint = jsonEncode(canonical);
      final cached = peer.replies[id];
      if (cached != null) {
        send(
          cached.$1 == fingerprint ? cached.$2 : reply(false, '同一指令 ID 不可改內容。'),
        );
        return;
      }
      bool accepted = false;
      String? error;
      if (action == 'pair_driver') {
        final code = decoded['pairing_code'];
        if (code is! String || !RegExp(r'^\d{6}$').hasMatch(code)) {
          throw const FormatException('配對碼須為六位數字。');
        }
        final now = DateTime.now();
        if (peer.blockedUntil != null && now.isBefore(peer.blockedUntil!)) {
          error = '配對嘗試過多，請稍後再試。';
        } else {
          accepted = c.pairDriver(
            socket,
            code,
            sessionId: sessionId is String ? sessionId : null,
          );
          if (accepted) {
            peer.failedPairings = 0;
          } else {
            error = c.error;
            if (++peer.failedPairings >= 3) {
              peer.failedPairings = 0;
              peer.blockedUntil = now.add(const Duration(seconds: 30));
            }
          }
        }
      } else if (action == 'heartbeat') {
        accepted = c.heartbeat(
          socket,
          sessionId: sessionId is String ? sessionId : null,
        );
        if (!accepted) error = c.error;
      } else {
        final taskId = decoded['task_id'];
        final revision = decoded['revision'];
        if (taskId is! String ||
            taskId.isEmpty ||
            taskId.length > 120 ||
            revision is! int ||
            revision < 1) {
          throw const FormatException('需求 ID 與版本不合法。');
        }
        accepted = switch (action) {
          'grant' => c.grant(socket, taskId, revision, context: context),
          'revoke' => c.revoke(socket, taskId, revision, context: context),
          'confirm' => c.confirm(socket, taskId, revision, context: context),
          'resume_confirm' => c.confirm(
            socket,
            taskId,
            revision,
            context: context,
            resume: true,
          ),
          'cancel' => c.cancelByDriver(
            socket,
            taskId,
            revision,
            context: context,
          ),
          _ => false,
        };
        if (!accepted) error = c.error;
      }
      final response = reply(accepted, accepted ? null : (error ?? '指令未接受。'));
      peer.replies[id] = (fingerprint, response);
      if (peer.replies.length > 128) {
        peer.replies.remove(peer.replies.keys.first);
      }
      send(response);
      _broadcast();
    } on FormatException catch (e) {
      send(reply(false, e.message));
    } catch (_) {
      send(reply(false, '指令未接受，請查看最新狀態。'));
    }
  }
}

class _RepairPeer {
  final replies = <String, (String, Map<String, dynamic>)>{};
  int failedPairings = 0;
  DateTime? blockedUntil;
}
