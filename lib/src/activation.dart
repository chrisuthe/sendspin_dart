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

/// Whether a declared pairing activity names a method and format the
/// matched PSK allows and the client currently offers.
bool _isPairingOffered({
  required SendspinPskCategory matched,
  required Set<String> activities,
  required String? pairingMethod,
  required String? pairingFormat,
  required Map<String, Set<String>> offeredPairMethods,
}) {
  if (!activities.contains(activityPairing)) return true;
  final formats = offeredPairMethods[pairingMethod];
  if (pairingMethod == null || formats == null) return false;
  // `pairing_psk` is the method if and only if the pairing PSK matched.
  if ((pairingMethod == 'pairing_psk') !=
      (matched == SendspinPskCategory.pairing)) {
    return false;
  }
  return pairingMethod != 'dynamic_pairing_code' ||
      formats.contains(pairingFormat);
}

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
  // The activity set and the roles, which is what unpaired access can change.
  bool activitiesAllowed(bool unpaired) =>
      _isAllowedSet(matched, unpaired, activities) &&
      (!hasRoles || isPlaybackCapable(matched, unpaired, activities));
  final pairingOffered = _isPairingOffered(
    matched: matched,
    activities: activities,
    pairingMethod: pairingMethod,
    pairingFormat: pairingFormat,
    offeredPairMethods: offeredPairMethods,
  );

  if (activitiesAllowed(unpairedAccess)) {
    return pairingOffered
        ? ActivationVerdict.admissible
        : ActivationVerdict.methodNotSupported;
  }
  // Rule 1 only applies when enabling unpaired access would make the whole
  // activation admissible, the pairing parameters included.
  final unpairedSession = matched != SendspinPskCategory.longTerm;
  if (unpairedSession &&
      !unpairedAccess &&
      activitiesAllowed(true) &&
      pairingOffered) {
    return ActivationVerdict.pairingRequired;
  }
  return ActivationVerdict.unauthorized;
}
