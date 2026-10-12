import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cockpit_design.dart';
import 'repair_screen.dart';
import 'repair_remote_model.dart';
import 'slm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  if (kRepairModelUrl.isEmpty) await initGemma();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '不用重講',
      theme: CockpitStyle.theme,
      home: const RepairScreen(),
    ),
  );
}
