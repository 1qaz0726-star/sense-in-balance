import 'cabin_policy.dart';
import 'protocol.dart';

/// Trusted local bridge from the original simulator to C policy. A repeated
/// envelope is never a new sample and cannot extend the three-second TTL.
class CabinCockpitSource {
  CabinCockpitSource(this.policy, this.sourceSession);
  final CabinPolicy policy;
  final String sourceSession;
  String? _lastSampleKey;
  double? _latestSourceTimestamp;
  int _sequence = 0, _episode = 0;
  bool _active = false;
  String get _episodeId => '$sourceSession-safety-$_episode';

  void sample(
    Envelope? event, {
    required bool running,
    required double wallNowSeconds,
  }) {
    if (event == null) {
      policy.refresh();
      return;
    }
    final key =
        '${event.eventId}|${event.ts}|$running|${event.availability.name}';
    if (key == _lastSampleKey) {
      policy.refresh();
      return;
    }
    _lastSampleKey = key;
    final ageSeconds = wallNowSeconds - event.ts;
    final now = policy.monotonicNow;
    final age = ageSeconds.isFinite && ageSeconds >= 0
        ? Duration(microseconds: (ageSeconds * 1000000).round())
        : null;
    // Preserve the source's age when registering against an existing event;
    // neither a clone with a new ID nor a delayed old envelope is fresh input.
    final timestampIsNew =
        _latestSourceTimestamp == null || event.ts > _latestSourceTimestamp!;
    final known =
        running &&
        event.availability == Avail.ok &&
        event.ts.isFinite &&
        event.ts > 0 &&
        timestampIsNew &&
        age != null &&
        age < policy.sourceTtl &&
        age <= now;
    if (timestampIsNew && event.ts.isFinite) _latestSourceTimestamp = event.ts;
    final active = known && event.decision.urgency == Urgency.safety;
    if (active && !_active) ++_episode;
    if (known) _active = active;
    policy.observe(
      CabinAttentionFrame(
        sourceId: CabinPolicy.safetySource,
        sourceSession: sourceSession,
        sequence: ++_sequence,
        episodeId: _episodeId,
        sampledAt: known ? now - age : now,
        known: known,
        active: known ? active : _active,
        mode: CabinDrivingMode.manual,
      ),
    );
  }
}
