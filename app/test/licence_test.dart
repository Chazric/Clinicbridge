import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clinicbridge/core/app_state.dart';
import 'package:clinicbridge/core/licence.dart';
import 'package:clinicbridge/demo/synthetic_data.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _Server {
  _Server(this.keyPair, this.publicHex);
  final SimpleKeyPair keyPair;
  final String publicHex;
  String status = 'active';
  DateTime expires = DateTime.now().add(const Duration(days: 20));
  final calls = <String>[];

  static Future<_Server> create() async {
    final kp = await Ed25519().newKeyPair();
    return _Server(kp, _hex((await kp.extractPublicKey()).bytes));
  }

  Future<Map<String, String>> sign(Map<String, dynamic> payload) async {
    final token = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    final sig = await Ed25519().sign(utf8.encode(token), keyPair: keyPair);
    return {'token': token, 'sig': base64Url.encode(sig.bytes).replaceAll('=', '')};
  }

  Future<Map<String, dynamic>> transport(String path, Map<String, dynamic> body) async {
    calls.add(path);
    if (path.endsWith('deactivate')) return {'ok': true};
    return sign({
      'v': 1,
      'device': body['device_id'],
      'status': status,
      'plan': 'monthly',
      'seats': 3,
      'devices_used': 1,
      'expires_at': status == 'inactive' ? null : expires.toUtc().toIso8601String(),
      'valid_until': DateTime.now().add(const Duration(days: 30)).toUtc().toIso8601String(),
    });
  }
}

Future<void> _register(AppState s) => s.registerPatient(
  givenName: 'Test',
  familyName: 'Patient',
  birthDate: DateTime(1980, 1, 1),
  sex: 'female',
  preferredLanguage: 'en',
  interpreterNeeded: false,
  location: 'Ward 1',
);

void main() {
  late _Server srv;
  late AppState s;
  setUp(() async {
    srv = await _Server.create();
    s = AppState(
      licenceVerifier: LicenceVerifier(publicKeyHex: srv.publicHex),
      licenceTransport: srv.transport,
    );
    await SyntheticData.load(s);
    await s.signIn(s.clinician('clin-okafor')!);
  });

  test('real-patient registration is blocked without a licence', () async {
    expect(s.licensed, isFalse);
    expect(() => _register(s), throwsA(isA<LicenceException>()));
  });

  test('activation verifies the signature, persists and unlocks registration', () async {
    final l = await s.activateLicence(' cb-abcd-efgh-jkmn-pqrs ');
    expect(l.status, 'active');
    expect(s.licensed, isTrue);
    expect(s.settings.licenceKey, 'CB-ABCD-EFGH-JKMN-PQRS');
    await _register(s);
    expect(s.patients.last.synthetic, isFalse);
    expect(s.audit.any((a) => a.action == 'licence-activated'), isTrue);

    final t = AppState(licenceVerifier: LicenceVerifier(publicKeyHex: srv.publicHex))..loadJson(s.toJson());
    await t.reloadLicence();
    expect(t.licensed, isTrue, reason: 'stored licence verifies offline');
    expect(t.settings.deviceId, s.settings.deviceId);
  });

  test('tampered, foreign-key and other-device licences are rejected', () async {
    await s.activateLicence('CB-ABCD-EFGH-JKMN-PQRS');
    final signed = await srv.sign({
      'v': 1,
      'device': s.settings.deviceId,
      'status': 'active',
      'seats': 1,
      'devices_used': 1,
      'expires_at': '2099-01-01T00:00:00Z',
      'valid_until': '2099-01-01T00:00:00Z',
    });
    final forged = base64Url
        .encode(
          utf8.encode(
            utf8
                .decode(base64Url.decode(base64Url.normalize(signed['token']!)))
                .replaceFirst('"seats":1', '"seats":99'),
          ),
        )
        .replaceAll('=', '');
    expect(await LicenceVerifier(publicKeyHex: srv.publicHex).verify(forged, signed['sig']!), isNull);
    final other = await _Server.create();
    expect(await LicenceVerifier(publicKeyHex: other.publicHex).verify(signed['token']!, signed['sig']!), isNull);
    expect(await LicenceVerifier().verify(signed['token']!, signed['sig']!), isNull, reason: 'production key differs');
    final mine = (await LicenceVerifier(publicKeyHex: srv.publicHex).verify(signed['token']!, signed['sig']!))!;
    expect(mine.isActiveFor('0' * 32, DateTime.now()), isFalse);
  });

  test('inactive or expired licences do not unlock; removal frees the seat', () async {
    srv.status = 'inactive';
    await s.activateLicence('CB-ABCD-EFGH-JKMN-PQRS');
    expect(s.licensed, isFalse);
    srv
      ..status = 'active'
      ..expires = DateTime.now().subtract(const Duration(minutes: 1));
    await s.refreshLicence();
    expect(s.licensed, isFalse);
    await s.removeLicence();
    expect(srv.calls.last, '/v1/billing/deactivate');
    expect(s.settings.licenceKey, isEmpty);
    expect(s.licence, isNull);
  });

  test('malformed keys are rejected before any network call', () async {
    expect(() => s.activateLicence('hello'), throwsA(isA<LicenceException>()));
    expect(srv.calls, isEmpty);
  });
}
