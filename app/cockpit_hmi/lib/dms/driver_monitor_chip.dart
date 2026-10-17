import 'package:flutter/material.dart';

import '../cockpit_design.dart';
import 'dms_monitor_state.dart';
import 'driver_state.dart';

/// 駕駛畫面上的小監測燈號：只顯示本機鏡頭狀態，不顯示影像。
class DriverMonitorChip extends StatelessWidget {
  const DriverMonitorChip({super.key, required this.state});
  final DriverMonitorState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final alerting =
            state.active &&
            (state.eyes.severity >= 2 || state.attention.severity >= 2);
        final color = switch (state.status) {
          DmsStatus.running => alerting ? Colors.redAccent : Colors.greenAccent,
          DmsStatus.starting => Colors.amber,
          DmsStatus.permissionDenied || DmsStatus.failed => Colors.orangeAccent,
          _ => CockpitStyle.muted,
        };
        return Semantics(
          label: '駕駛監測：${dmsChipText(state)}',
          child: Row(
            key: const ValueKey('dms_chip'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '駕駛監測：${dmsChipText(state)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CockpitStyle.muted,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
