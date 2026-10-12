import 'package:flutter/material.dart';

import 'cockpit_instruments.dart';
import 'protocol.dart';

/// Event content changes inside a permanent slot, never the instrument bounds.
/// This follows the original dashboard's reserved blind-spot region.
class CockpitAlertSlot extends StatelessWidget {
  const CockpitAlertSlot({
    super.key,
    required this.event,
    required this.fresh,
    this.compact = false,
  });

  final Envelope? event;
  final bool fresh;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final show =
        !fresh ||
        event == null ||
        event!.availability != Avail.ok ||
        event!.decision.urgency != Urgency.silent;
    return SizedBox(
      height: compact ? 48 : 64,
      width: double.infinity,
      child: show
          ? Align(
              alignment: Alignment.center,
              child: CockpitSafetyBanner(
                event: event,
                fresh: fresh,
                compact: compact,
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
