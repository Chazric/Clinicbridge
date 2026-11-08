import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';

import 'interpreter.dart';
import 'vault.dart';

class KeychainSecretStore implements SecretStore {
  static const _s = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

Future<Directory> vaultDirectory() async => getApplicationSupportDirectory();

/// Google ML Kit on-device translation: text never leaves the phone.
/// Language models (~30 MB each) are downloaded once, then work offline.
class OnDeviceTranslation implements TranslationService {
  final _models = OnDeviceTranslatorModelManager();
  final _cache = <String, OnDeviceTranslator>{};

  static bool supports(String code) => TranslateLanguage.values.any((l) => l.bcpCode == code);

  Future<bool> isReady(String code) => _models.isModelDownloaded(code);

  Future<bool> ensureModel(String code) async {
    if (await _models.isModelDownloaded(code)) return true;
    return _models.downloadModel(code, isWifiRequired: false);
  }

  @override
  Future<String> translate(String text, {required String from, required String to}) async {
    if (from == to) return text;
    final src = TranslateLanguage.values.firstWhere((l) => l.bcpCode == from);
    final dst = TranslateLanguage.values.firstWhere((l) => l.bcpCode == to);
    await ensureModel(from);
    await ensureModel(to);
    final t = _cache.putIfAbsent('$from>$to', () => OnDeviceTranslator(sourceLanguage: src, targetLanguage: dst));
    return t.translateText(text);
  }
}

class BiometricGate {
  final _auth = LocalAuthentication();

  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(localizedReason: 'Unlock ClinicBridge', biometricOnly: true);
    } catch (_) {
      return false;
    }
  }
}
