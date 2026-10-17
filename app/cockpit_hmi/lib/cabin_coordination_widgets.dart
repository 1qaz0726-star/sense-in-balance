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

/// 駕駛監測燈號文字；null 代表這個場景沒有駕駛端鏡頭（不顯示）。
String? cabinDriverMonitorLabel(Map? context) {
  final attention = context?['attention'];
  final monitor = attention is Map ? attention['driver_monitor'] : null;
  if (monitor is! Map) return null;
  return switch (monitor['state']) {
    'live' => switch (monitor['reason']) {
      'drowsy' => '駕駛監測：閉眼',
      'distracted' => '駕駛監測：視線偏離',
      _ => '駕駛監測：看路中',
    },
    'no_face' => '駕駛監測：偵測不到臉',
    'stale' => '駕駛監測：訊號中斷',
    _ => null,
  };
}

String cabinAttentionHeadline(Map? context) {
  final attention = context?['attention'];
  final mode = attention is Map ? attention['mode'] : null;
  if (mode == 'handoverRequested') return '接管提醒（模擬）';
  final blockers = attention is Map && attention['blockers'] is List
      ? attention['blockers'] as List
      : const [];
  // 駕駛監測是真實鏡頭訊號，不加「模擬」字樣。
  if (blockers.contains('driver_drowsy')) return '偵測到閉眼，請先休息';
  if (blockers.contains('driver_distracted')) return '視線離開道路，請先看路';
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
            if (cabinDriverMonitorLabel(contextData) case final monitor?)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  monitor,
                  key: const ValueKey('cabin_driver_monitor'),
                  style: cockpitText(11, color: CockpitStyle.muted),
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
