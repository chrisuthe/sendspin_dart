// ABOUTME: Admissibility rules for server/activate: which activity sets,
// ABOUTME: roles and pairing methods the matched PSK lets a server declare.
import 'psk.dart';

/// Activity names carried in `server/activate`.
const String activityPlayback = 'playback';
const String activityPairing = 'pairing';

/// How the client responds to a `server/activate`.
enum ActivationVerdict {
  /// The activation satisfies the constraints and is applied.
  admissible,

  /// Close with `client/goodbye` reason `pairing_required`: the session is
  /// unpaired, unpaired access is off, and turning it on would have made the
  /// activation admissible.
  pairingRequired,

  /// Close with `client/goodbye` reason `unauthorized`.
  unauthorized,

  /// Reply `pair/abort` reason `method_not_supported`; the connection stays
  /// open.
  methodNotSupported,
}

/// Whether [activities] is a set the server may declare on a connection
/// whose handshake matched a PSK of category [matched].
bool _isAllowedSet(
    SendspinPskCategory matched, bool unpairedAccess, Set<String> activities) {
  for (final activity in activities) {
    if (activity != activityPlayback && activity != activityPairing) {
      return false;
    }
  }
  if (matched == SendspinPskCategory.longTerm) {
    return !activities.contains(activityPairing);
  }
  // Pairing PSK or Sentinel: playback only with unpaired access.
  return unpairedAccess || !activities.contains(activityPlayback);
}

/// A connection is playback-capable when its activities extended with
/// `playback` are an allowed set. Only such a connection may carry roles.
bool isPlaybackCapable(SendspinPskCategory matched, bool unpairedAccess,
        Set<String> activities) =>
    _isAllowedSet(matched, unpairedAccess, {...activities, activityPlayback});

bool _isAdmissible({
  required SendspinPskCategory matched,
  required bool unpairedAccess,
  required Set<String> activities,
  required bool hasRoles,
}) =>
    _isAllowedSet(matched, unpairedAccess, activities) &&
    (!hasRoles || isPlaybackCapable(matched, unpairedAccess, activities));

/// Decides how to respond to a `server/activate`, selecting the response by
/// the first rule of the spec that applies.
///
/// [activeRoles] is the list the message carried, or null when it omitted
/// the field. [offeredPairMethods] maps each pairing method the client
/// currently offers to the emission formats it offers for it.
ActivationVerdict evaluateActivation({
  required SendspinPskCategory matched,
  required bool unpairedAccess,
  required Set<String> activities,
  required List<String>? activeRoles,
  required String? pairingMethod,
  required String? pairingFormat,
  required Map<String, Set<String>> offeredPairMethods,
}) {
  final hasRoles = activeRoles != null && activeRoles.isNotEmpty;
  final allowed = _isAdmissible(
    matched: matched,
    unpairedAccess: unpairedAccess,
    activities: activities,
    hasRoles: hasRoles,
  );

  if (!allowed) {
    final unpaired = matched != SendspinPskCategory.longTerm;
    if (unpaired &&
        !unpairedAccess &&
        _isAdmissible(
          matched: matched,
          unpairedAccess: true,
          activities: activities,
          hasRoles: hasRoles,
        )) {
      return ActivationVerdict.pairingRequired;
    }
    return ActivationVerdict.unauthorized;
  }

  if (activities.contains(activityPairing)) {
    // `pairing_psk` is the method if and only if the pairing PSK matched.
    final wantsPsk = pairingMethod == 'pairing_psk';
    final formats = offeredPairMethods[pairingMethod];
    if (pairingMethod == null ||
        formats == null ||
        wantsPsk != (matched == SendspinPskCategory.pairing) ||
        (pairingMethod == 'dynamic_pairing_code' &&
            !formats.contains(pairingFormat))) {
      return ActivationVerdict.methodNotSupported;
    }
  }
  return ActivationVerdict.admissible;
}
