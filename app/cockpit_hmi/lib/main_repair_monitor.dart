// Native phone companion for the PC demonstration. No model and no controls.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cockpit_design.dart';
import 'main_repair_web.dart' show RepairMonitor;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(
    MaterialApp(
      title: '不用重講・第二屏',
      debugShowCheckedModeBanner: false,
      theme: CockpitStyle.theme,
      home: RepairMonitor(
        url: Uri.parse(
          const String.fromEnvironment(
            'REPAIR_MONITOR_URL',
            defaultValue: 'ws://10.0.2.2:8767/repair',
          ),
        ),
      ),
    ),
  );
}
