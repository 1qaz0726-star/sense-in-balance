import 'package:flutter/material.dart';

import 'cockpit_design.dart';

/// Read-only presentation of host policy. Missing C state is never clear.
String cabinAttentionPhase(Map? context) => context?['attention'] is Map
    ? '${(context!['attention'] as Map)['phase']}'
    : 'unknown';

bool cabinAttentionBlocked(Map? context) =>
    context != null &&
    cabinAttentionPhase(context) != 'clear' &&
    cabinAttentionPhase(context) != 'resumeRequired' &&
    cabinAttentionPhase(context) != 'resume_required';

bool cabinRequiresResume(Map? context) =>
    context?['requires_resume'] == true ||
    cabinAttentionPhase(context) == 'resumeRequired' ||
    cabinAttentionPhase(context) == 'resume_required';

bool cabinSettingReadable(Map? context, String name) {
  if (context == null) return true;
  final profile = context['profile'];
  if (profile is! Map) return false;
  final readable = profile['readable'];
  if (readable is List) return readable.contains(name);
  if (readable is Map) return readable[name] == true;
  final supported = profile['supported'];
  return supported is List && supported.contains(name);
}

Map cabinUnsupported(Map? context) {
  final capability = context?['capability'];
  return capability is Map && capability['unsupported'] is Map
      ? capability['unsupported'] as Map
      : const {};
}

String cabinAttentionHeadline(Map? context) {
  final attention = context?['attention'];
  final mode = attention is Map ? attention['mode'] : null;
  if (mode == 'handoverRequested') return '接管提醒（模擬）';
  if (mode == 'unknown' || cabinAttentionPhase(context) == 'unknown') {
    return '駕駛模式訊號未確認';
  }
  return '先專注駕駛';
}

/// Always occupies 54 logical pixels, regardless of attention changes.
/// This sits outside the instrument body so warnings cannot resize gauges.
class CabinAttentionStrip extends StatelessWidget {
  const CabinAttentionStrip({
    super.key,
    required this.contextData,
    this.onViewSummary,
    this.completed = false,
  });
  final Map? contextData;
  final VoidCallback? onViewSummary;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final blocked = cabinAttentionBlocked(contextData);
    final resume = cabinRequiresResume(contextData);
    final text = blocked
        ? '${cabinAttentionHeadline(contextData)} · 需求已保留'
        : resume
        ? '需求已保留 · 可查看最新摘要'
        : completed
        ? '模擬回報已收到 · 尚未連接真車'
        : '乘客整理需求 · 駕駛確認後才套用';
    return SizedBox(
      key: const ValueKey('cabin_attention_strip'),
      height: 54,
      child: Container(
        alignment: Alignment.centerLeft,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: CockpitStyle.line, width: .5)),
        ),
        child: Row(
          children: [
            Icon(
              blocked
                  ? Icons.pause
                  : resume
                  ? Icons.bookmark_outline
                  : Icons.link,
              color: blocked ? CockpitStyle.amber : CockpitStyle.accent,
              size: 16,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: cockpitText(
                  12,
                  color: blocked ? CockpitStyle.amber : CockpitStyle.muted,
                ),
              ),
            ),
            if (resume && !blocked && onViewSummary != null)
              TextButton(
                key: const ValueKey('cabin_view_latest'),
                onPressed: onViewSummary,
                child: const Text('查看摘要'),
              ),
          ],
        ),
      ),
    );
  }
}
