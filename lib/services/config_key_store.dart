import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/services/age_crypto.dart';
import 'package:fl_clash/utils/safe_storage.dart';

/// Per-device X25519 identity used to encrypt oixCloud configs at rest.
///
/// The 32-byte seed is kept in platform secure storage (Keychain / DPAPI /
/// libsecret via [SafeStorage]) and injected into the core at init so the core
/// can decrypt the same age blobs. This replaces the shared compile-time
/// profile key for at-rest encryption, so extracting the binary no longer
/// yields a key that decrypts every install's stored config.
class ConfigKeyStore {
  ConfigKeyStore._();

  static const _seedKey = 'config_age_seed';
  static String? _cachedSeedBase64;
  static AgeIdentity? _cachedIdentity;

  /// Base64 of the 32-byte seed, generating and persisting one on first use.
  /// Injected into the core via `InitParams.configAgeSecretKey`.
  static Future<String> seedBase64() async {
    final cached = _cachedSeedBase64;
    if (cached != null) return cached;

    var stored = await SafeStorage.read(_seedKey);
    if (stored == null || stored.isEmpty) {
      stored = base64Encode(_randomSeed());
      await SafeStorage.write(_seedKey, stored);
    }
    _cachedSeedBase64 = stored;
    return stored;
  }

  /// Identity derived from the persistent seed, for at-rest encryption.
  static Future<AgeIdentity> identity() async {
    final cached = _cachedIdentity;
    if (cached != null) return cached;
    final identity = await AgeCrypto.identityFromSeed(
      base64Decode(await seedBase64()),
    );
    _cachedIdentity = identity;
    return identity;
  }

  static Uint8List _randomSeed() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
  }
}
