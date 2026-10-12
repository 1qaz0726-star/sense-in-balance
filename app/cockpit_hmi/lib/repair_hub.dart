import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'repair_task.dart';

/// Read-only driver display. Only the local operator can change or confirm a
/// task in this slice; multi-person authority is intentionally not invented.
class RepairHub {
  RepairHub(
    this.controller, {
    required this.modelStatus,
    required this.asset,
    this.cabinState,
    this.cockpitEvent,
    this.cockpitSignals,
  });
  final RepairController controller;
  final String Function() modelStatus;
  final Future<List<int>?> Function(String) asset;
  final Map<String, int> Function()? cabinState;
  final Map<String, dynamic>? Function()? cockpitEvent;
  final Listenable? cockpitSignals;
  HttpServer? _server;
  Timer? _heartbeat;
  int _generation = 0;
  final _clients = <WebSocket>{};
  List<String> addresses = [];
  static const port = 8767;

  Map<String, dynamic> status() => {
    'type': 'repair_status',
    'schema': 1,
    'at': DateTime.now().millisecondsSinceEpoch,
    'model': modelStatus(),
    'mode': '文字輸入／車控模擬',
    if (cabinState != null) 'cabin_state': cabinState!(),
    if (cockpitEvent != null) 'cockpit_event': cockpitEvent!(),
    'task': controller.snapshot.toJson(),
  };

  Future<void> start() async {
    if (_server != null) return;
    final generation = ++_generation;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
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
    _heartbeat = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _broadcast(),
    );
    server.listen((request) async {
      if (request.uri.path == '/repair' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _clients.add(socket);
        socket.add(jsonEncode(status()));
        socket.listen(
          (_) {},
          onDone: () => _clients.remove(socket),
          onError: (_) => _clients.remove(socket),
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
    final message = jsonEncode(status());
    for (final c in [..._clients]) {
      try {
        c.add(message);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  Future<void> stop() async {
    ++_generation; // A pending start must not revive a disposed screen.
    controller.removeListener(_broadcast);
    cockpitSignals?.removeListener(_broadcast);
    _heartbeat?.cancel();
    _heartbeat = null;
    final server = _server;
    _server = null;
    for (final c in [..._clients]) {
      await c.close();
    }
    _clients.clear();
    await server?.close(force: true);
  }
}
