// Native driver companion: no model; paired driver grants and confirms tasks.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'cockpit_design.dart';
import 'main_repair_web.dart' show RepairMonitor;

const _defaultUrl = String.fromEnvironment(
  'REPAIR_MONITOR_URL',
  defaultValue: 'ws://10.0.2.2:8767/repair',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(
    MaterialApp(
      title: '不用重講・第二屏',
      debugShowCheckedModeBanner: false,
      theme: CockpitStyle.theme,
      home: const MonitorHostPicker(),
    ),
  );
}

final _ipv4 = RegExp(
  r'^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$',
);

/// 主控 IP → 駕駛端連線網址；不是 IPv4 就回 null。連線埠與路徑沿用建置預設。
Uri? monitorUrlForHost(String input) {
  final ip = input.trim();
  return _ipv4.hasMatch(ip) ? Uri.parse(_defaultUrl).replace(host: ip) : null;
}

/// 實體手機連主控平板：主控的區網 IP 每次可能不同，所以開 App 先填（記住上次的值），
/// 不必為了換 IP 重建 APK。
class MonitorHostPicker extends StatefulWidget {
  const MonitorHostPicker({super.key});

  @override
  State<MonitorHostPicker> createState() => _MonitorHostPickerState();
}

class _MonitorHostPickerState extends State<MonitorHostPicker> {
  final host = TextEditingController(text: Uri.parse(_defaultUrl).host);
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/monitor_host.txt');

  Future<void> _load() async {
    try {
      final saved = (await (await _file()).readAsString()).trim();
      if (_ipv4.hasMatch(saved) && mounted) setState(() => host.text = saved);
    } catch (_) {
      // 第一次使用：沿用建置時的預設值。
    }
  }

  Future<void> _connect() async {
    final url = monitorUrlForHost(host.text);
    if (url == null) {
      setState(() => error = '請輸入主控平板的 IPv4 位址，例如 192.168.43.120');
      return;
    }
    try {
      await (await _file()).writeAsString(url.host);
    } catch (_) {
      // 記不住，下次再填就好，不影響連線。
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => RepairMonitor(url: url)),
    );
  }

  @override
  void dispose() {
    host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('連接主控平板', style: cockpitText(24)),
                const SizedBox(height: 8),
                Text(
                  '主控平板「連接駕駛屏」頁面會顯示它的 IP。',
                  style: cockpitText(13, color: CockpitStyle.muted),
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const ValueKey('monitor_host'),
                  controller: host,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onSubmitted: (_) => _connect(),
                  style: cockpitText(20, letterSpacing: 1),
                  decoration: InputDecoration(
                    labelText: '主控 IP',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('monitor_connect'),
                  onPressed: _connect,
                  child: const Text('連線'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
