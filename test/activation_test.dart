import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

const _lt = SendspinPskCategory.longTerm;
const _pr = SendspinPskCategory.pairing;
const _sn = SendspinPskCategory.sentinel;

ActivationVerdict _verdict(
  SendspinPskCategory matched,
  List<String> activities, {
  bool unpairedAccess = false,
  List<String>? activeRoles,
  String? method,
  String? format,
  Map<String, Set<String>> offered = const {'pairing_psk': {}},
}) =>
    evaluateActivation(
      matched: matched,
      unpairedAccess: unpairedAccess,
      activities: activities.toSet(),
      activeRoles: activeRoles,
      pairingMethod: method,
      pairingFormat: format,
      offeredPairMethods: offered,
    );

void main() {
  group('allowed activity sets', () {
    test('a long-term session allows [] and [playback]', () {
      expect(_verdict(_lt, []), ActivationVerdict.admissible);
      expect(_verdict(_lt, ['playback']), ActivationVerdict.admissible);
      expect(_verdict(_lt, ['playback'], activeRoles: ['player@v1']),
          ActivationVerdict.admissible);
    });

    test('a long-term session does not allow pairing', () {
      expect(_verdict(_lt, ['pairing'], method: 'pairing_psk'),
          ActivationVerdict.unauthorized);
      expect(_verdict(_lt, ['playback', 'pairing'], method: 'pairing_psk'),
          ActivationVerdict.unauthorized);
    });

    test('an unpaired session allows [] and [pairing] without unpaired access',
        () {
      for (final matched in [_pr, _sn]) {
        expect(_verdict(matched, []), ActivationVerdict.admissible);
      }
      expect(_verdict(_pr, ['pairing'], method: 'pairing_psk'),
          ActivationVerdict.admissible);
    });

    test('an unpaired session allows playback with unpaired access', () {
      for (final matched in [_pr, _sn]) {
        expect(
            _verdict(matched, ['playback'],
                unpairedAccess: true, activeRoles: ['player@v1']),
            ActivationVerdict.admissible);
      }
      expect(
          _verdict(_pr, ['playback', 'pairing'],
              unpairedAccess: true, method: 'pairing_psk'),
          ActivationVerdict.admissible);
    });

    test('an unknown activity is not an allowed set', () {
      expect(_verdict(_lt, ['dancing']), ActivationVerdict.unauthorized);
    });
  });

  group('pairing_required', () {
    test('the spec worked example', () {
      // Sentinel-keyed, unpaired access disabled, playback with a role.
      expect(_verdict(_sn, ['playback'], activeRoles: ['player@v1']),
          ActivationVerdict.pairingRequired);
    });

    test('roles on an unpaired idle connection without unpaired access', () {
      // [] is allowed, but roles need a playback-capable connection, which
      // enabling unpaired access would give.
      expect(_verdict(_sn, [], activeRoles: ['player@v1']),
          ActivationVerdict.pairingRequired);
    });

    test('does not apply when unpaired access would not fix it', () {
      expect(
          _verdict(_sn, ['playback', 'bogus']), ActivationVerdict.unauthorized);
    });

    test('does not apply when the pairing method would still be refused', () {
      // Enabling unpaired access would allow [playback, pairing], but
      // pairing_psk on a Sentinel session stays inadmissible, so the first
      // rule does not apply and the second one does.
      expect(_verdict(_sn, ['playback', 'pairing'], method: 'pairing_psk'),
          ActivationVerdict.unauthorized);
    });

    test('does not apply to a paired session', () {
      expect(_verdict(_lt, ['pairing'], method: 'pairing_psk'),
          ActivationVerdict.unauthorized);
    });
  });

  group('playback-capable connections', () {
    test('roles are allowed without playback when the set stays capable', () {
      expect(_verdict(_lt, [], activeRoles: ['player@v1']),
          ActivationVerdict.admissible);
      expect(
          _verdict(_sn, [], unpairedAccess: true, activeRoles: ['player@v1']),
          ActivationVerdict.admissible);
    });

    test('an empty role list is fine on a connection that is not capable', () {
      expect(_verdict(_sn, [], activeRoles: []), ActivationVerdict.admissible);
    });
  });

  group('pairing method', () {
    test('pairing_psk requires the pairing PSK to have matched', () {
      expect(_verdict(_sn, ['pairing'], method: 'pairing_psk'),
          ActivationVerdict.methodNotSupported);
    });

    test('a code method is not allowed on a pairing-PSK session', () {
      expect(
          _verdict(_pr, ['pairing'],
              method: 'static_pairing_code',
              offered: {'pairing_psk': {}, 'static_pairing_code': {}}),
          ActivationVerdict.methodNotSupported);
    });

    test('a method the client does not offer is refused', () {
      expect(_verdict(_sn, ['pairing'], method: 'static_pairing_code'),
          ActivationVerdict.methodNotSupported);
      expect(_verdict(_sn, ['pairing'], method: 'made_up'),
          ActivationVerdict.methodNotSupported);
    });

    test('a missing method is refused', () {
      expect(_verdict(_pr, ['pairing']), ActivationVerdict.methodNotSupported);
    });

    test('an offered code method on a Sentinel session is admissible', () {
      expect(
          _verdict(_sn, ['pairing'],
              method: 'static_pairing_code',
              offered: {'pairing_psk': {}, 'static_pairing_code': {}}),
          ActivationVerdict.admissible);
    });

    test('a dynamic code needs an offered emission format', () {
      const offered = {
        'pairing_psk': <String>{},
        'dynamic_pairing_code': {'digits'},
      };
      expect(
          _verdict(_sn, ['pairing'],
              method: 'dynamic_pairing_code',
              format: 'digits',
              offered: offered),
          ActivationVerdict.admissible);
      expect(
          _verdict(_sn, ['pairing'],
              method: 'dynamic_pairing_code',
              format: 'qr_code',
              offered: offered),
          ActivationVerdict.methodNotSupported);
      expect(
          _verdict(_sn, ['pairing'],
              method: 'dynamic_pairing_code', offered: offered),
          ActivationVerdict.methodNotSupported);
    });

    test('the pairing object is ignored when pairing is not an activity', () {
      expect(_verdict(_lt, ['playback'], method: 'made_up'),
          ActivationVerdict.admissible);
    });
  });

  group('isPlaybackCapable', () {
    test('follows the allowed sets for the matched PSK', () {
      expect(isPlaybackCapable(_lt, false, const {}), isTrue);
      expect(isPlaybackCapable(_sn, false, const {}), isFalse);
      expect(isPlaybackCapable(_sn, true, const {'pairing'}), isTrue);
      expect(isPlaybackCapable(_lt, true, const {'pairing'}), isFalse);
    });
  });
}
