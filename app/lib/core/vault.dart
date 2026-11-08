import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Abstracts the platform keystore (iOS Keychain / Android Keystore).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class InMemorySecretStore implements SecretStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// AES-256-GCM encrypted file storage. The data key lives only in the
/// platform keystore; deleting it renders every copy of the vault unreadable
/// (crypto-shredding). The previous good file is kept as `.bak` for recovery.
class Vault {
  Vault({required this.dir, required this.secrets});

  final Directory dir;
  final SecretStore secrets;
  static const _keyName = 'clinicbridge.vault.key.v1';
  static final _aes = AesGcm.with256bits();

  File get file => File('${dir.path}/clinicbridge.vault');
  File get backup => File('${dir.path}/clinicbridge.vault.bak');

  Future<SecretKey> _key() async {
    final existing = await secrets.read(_keyName);
    if (existing != null) return SecretKey(base64Decode(existing));
    final k = await _aes.newSecretKey();
    await secrets.write(_keyName, base64Encode(await k.extractBytes()));
    return k;
  }

  static Map<String, String> _pack(SecretBox box) => {
        'v': '1',
        'n': base64Encode(box.nonce),
        'c': base64Encode(box.cipherText),
        'm': base64Encode(box.mac.bytes),
      };

  static SecretBox _unpack(Map<String, dynamic> j) => SecretBox(
        base64Decode(j['c']),
        nonce: base64Decode(j['n']),
        mac: Mac(base64Decode(j['m'])),
      );

  Future<void> save(Map<String, dynamic> data) async {
    final box = await _aes.encrypt(utf8.encode(jsonEncode(data)), secretKey: await _key());
    await dir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_pack(box)), flush: true);
    if (await file.exists()) await file.copy(backup.path);
    await tmp.rename(file.path);
  }

  Future<Map<String, dynamic>?> load() async {
    for (final f in [file, backup]) {
      if (!await f.exists()) continue;
      try {
        final box = _unpack(jsonDecode(await f.readAsString()));
        final clear = await _aes.decrypt(box, secretKey: await _key());
        return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      } catch (_) {
        continue; // fall back to the backup copy
      }
    }
    return null;
  }

  Future<void> destroy() async {
    await secrets.delete(_keyName);
    for (final f in [file, backup, File('${file.path}.tmp')]) {
      if (await f.exists()) await f.delete();
    }
  }

  // ----- passphrase-protected portable backup -----
  static final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);

  static Future<String> exportBackup(Map<String, dynamic> data, String passphrase) async {
    if (passphrase.length < 10) throw VaultException('Use a passphrase of at least 10 characters.');
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final key = await _kdf.deriveKeyFromPassword(password: passphrase, nonce: salt);
    final box = await _aes.encrypt(utf8.encode(jsonEncode(data)), secretKey: key);
    return jsonEncode({'format': 'clinicbridge-backup', ..._pack(box), 's': base64Encode(salt)});
  }

  static Future<Map<String, dynamic>> importBackup(String blob, String passphrase) async {
    final j = jsonDecode(blob) as Map<String, dynamic>;
    if (j['format'] != 'clinicbridge-backup') throw VaultException('Not a ClinicBridge backup.');
    final key = await _kdf.deriveKeyFromPassword(password: passphrase, nonce: base64Decode(j['s']));
    try {
      final clear = await _aes.decrypt(_unpack(j), secretKey: key);
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } on SecretBoxAuthenticationError {
      throw VaultException('Wrong passphrase or damaged backup.');
    }
  }
}

/// PIN stored only as a salted PBKDF2 hash, with escalating lockout.
class PinGuard {
  PinGuard(this.secrets);
  final SecretStore secrets;
  static const _hashKey = 'clinicbridge.pin.v1';
  static const _failKey = 'clinicbridge.pin.fails';
  static const _lockKey = 'clinicbridge.pin.lockedUntil';
  static final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 60000, bits: 256);

  Future<bool> get isSet async => (await secrets.read(_hashKey)) != null;

  static String? weakness(String pin) {
    if (!RegExp(r'^\d{6,}$').hasMatch(pin)) return 'Use at least 6 digits.';
    if (RegExp(r'^(\d)\1+$').hasMatch(pin)) return 'Avoid repeated digits.';
    const seq = '01234567890';
    const rev = '09876543210';
    if (seq.contains(pin) || rev.contains(pin)) return 'Avoid sequences.';
    return null;
  }

  Future<void> setPin(String pin) async {
    final w = weakness(pin);
    if (w != null) throw VaultException(w);
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final k = await _kdf.deriveKeyFromPassword(password: pin, nonce: salt);
    await secrets.write(_hashKey, '${base64Encode(salt)}:${base64Encode(await k.extractBytes())}');
    await secrets.delete(_failKey);
    await secrets.delete(_lockKey);
  }

  Future<Duration?> lockedFor({DateTime? now}) async {
    final until = await secrets.read(_lockKey);
    if (until == null) return null;
    final left = DateTime.parse(until).difference(now ?? DateTime.now());
    return left.isNegative ? null : left;
  }

  Future<bool> check(String pin, {DateTime? now}) async {
    if (await lockedFor(now: now) != null) return false;
    final stored = await secrets.read(_hashKey);
    if (stored == null) return false;
    final parts = stored.split(':');
    final k = await _kdf.deriveKeyFromPassword(password: pin, nonce: base64Decode(parts[0]));
    final ok = _constantTimeEq(base64Encode(await k.extractBytes()), parts[1]);
    if (ok) {
      await secrets.delete(_failKey);
      return true;
    }
    final fails = int.parse(await secrets.read(_failKey) ?? '0') + 1;
    await secrets.write(_failKey, '$fails');
    if (fails >= 5) {
      final minutes = 1 << (fails - 5).clamp(0, 6);
      await secrets.write(_lockKey, (now ?? DateTime.now()).add(Duration(minutes: minutes)).toIso8601String());
    }
    return false;
  }

  static bool _constantTimeEq(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }

  Future<void> clear() async {
    for (final k in [_hashKey, _failKey, _lockKey]) {
      await secrets.delete(k);
    }
  }
}
