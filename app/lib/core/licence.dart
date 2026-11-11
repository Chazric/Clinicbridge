import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Ed25519 public key of the ClinicBridge billing server (private key lives only on the server).
const licencePublicKeyHex = '466662f194202ffa57a0dc9e59934e0997fd9586e21adcb95fb3765d017718d4';
const billingBaseUrl = String.fromEnvironment(
  'CLINICBRIDGE_BILLING_URL',
  defaultValue: 'https://clinicbridge-billing.onrender.com',
);

class LicenceException implements Exception {
  LicenceException(this.message);
  final String message;
  @override
  String toString() => message;
}

String newDeviceId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// A server-signed licence for one device. Only the licence key and a random per-install
/// device id are ever sent to the billing server — never patient data.
class Licence {
  Licence({
    required this.status,
    required this.plan,
    required this.seats,
    required this.devicesUsed,
    required this.device,
    required this.expiresAt,
    required this.validUntil,
  });

  final String status;
  final String? plan;
  final int seats;
  final int devicesUsed;
  final String device;
  final DateTime? expiresAt;
  final DateTime validUntil;

  factory Licence.fromJson(Map<String, dynamic> j) => Licence(
    status: j['status'] as String,
    plan: j['plan'] as String?,
    seats: (j['seats'] as num?)?.toInt() ?? 0,
    devicesUsed: (j['devices_used'] as num?)?.toInt() ?? 0,
    device: j['device'] as String,
    expiresAt: j['expires_at'] == null ? null : DateTime.parse(j['expires_at'] as String),
    validUntil: DateTime.parse(j['valid_until'] as String),
  );

  bool isActiveFor(String deviceId, DateTime now) =>
      (status == 'active' || status == 'trialing') &&
      device == deviceId &&
      expiresAt != null &&
      now.isBefore(expiresAt!) &&
      now.isBefore(validUntil);

  /// Signed licences must be refreshed online at least this often.
  bool needsRefresh(DateTime now) => validUntil.difference(now).inDays < 7;
}

class LicenceVerifier {
  LicenceVerifier({this.publicKeyHex = licencePublicKeyHex});
  final String publicKeyHex;

  static List<int> _hex(String h) => [
    for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
  ];
  static List<int> _b64(String s) => base64Url.decode(base64Url.normalize(s));

  /// Returns the licence only if the signature is valid; tampered or foreign tokens yield null.
  Future<Licence?> verify(String token, String sig) async {
    try {
      final ok = await Ed25519().verify(
        utf8.encode(token),
        signature: Signature(_b64(sig), publicKey: SimplePublicKey(_hex(publicKeyHex), type: KeyPairType.ed25519)),
      );
      if (!ok) return null;
      final j = jsonDecode(utf8.decode(_b64(token))) as Map<String, dynamic>;
      if (j['v'] != 1) return null;
      return Licence.fromJson(j);
    } catch (_) {
      return null;
    }
  }
}

typedef LicenceTransport = Future<Map<String, dynamic>> Function(String path, Map<String, dynamic> body);

Future<Map<String, dynamic>> httpLicenceTransport(String path, Map<String, dynamic> body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse('$billingBaseUrl$path'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 60));
    final text = await res.transform(utf8.decoder).join();
    final j = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
    if (res.statusCode != 200) throw LicenceException('Licence server: ${j['error'] ?? 'HTTP ${res.statusCode}'}');
    return j;
  } on SocketException {
    throw LicenceException('No connection to the licence server. Try again when online.');
  } finally {
    client.close();
  }
}
