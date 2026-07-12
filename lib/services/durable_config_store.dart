import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/durable_file.dart';
import 'package:fl_clash/services/age_crypto.dart';

class DurableConfigStore {
  final Future<AgeIdentity> Function() _identityProvider;

  DurableConfigStore({required Future<AgeIdentity> Function() identityProvider})
    : _identityProvider = identityProvider;

  Future<Map<String, Object?>?> read(String path) async {
    final target = File(path);
    final temporary = File('$path.tmp');
    final backup = File('$path.old');
    final candidates = [target, temporary, backup];
    final candidateExists = await Future.wait(
      candidates.map((file) => file.exists()),
    );
    if (!candidateExists.any((exists) => exists)) {
      return null;
    }
    final identity = await _identityProvider();
    for (final candidate in candidates) {
      if (!await candidate.exists()) {
        continue;
      }
      try {
        final plaintext = await AgeCrypto.decrypt(
          await candidate.readAsBytes(),
          identity,
        );
        final value = Map<String, Object?>.from(
          jsonDecode(utf8.decode(plaintext)) as Map,
        );
        if (!identical(candidate, target)) {
          if (await target.exists()) {
            await target.delete();
          }
          await durableRename(candidate.path, target.path);
        }
        for (final stale in [temporary, backup]) {
          if (await stale.exists()) {
            try {
              await stale.delete();
            } catch (_) {}
          }
        }
        return value;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<void> write(String path, Object config) async {
    final identity = await _identityProvider();
    final ciphertext = await AgeCrypto.encrypt(
      utf8.encode(jsonEncode(config)),
      identity.publicKeyBytes,
    );
    final target = File(path);
    await durableCreateDirectory(target.parent.path);
    final temporary = File('$path.tmp');
    if (await temporary.exists()) {
      await temporary.delete();
    }
    await temporary.writeAsBytes(ciphertext, flush: true);
    if (await target.exists()) {
      final backup = File('$path.old');
      if (await backup.exists()) {
        await backup.delete();
      }
      await durableRename(target.path, backup.path);
      try {
        await durableRename(temporary.path, target.path);
        await backup.delete();
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await durableRename(backup.path, target.path);
        }
        rethrow;
      }
    } else {
      await durableRename(temporary.path, target.path);
    }
  }

  Future<void> clear(String path) async {
    for (final file in [File(path), File('$path.tmp'), File('$path.old')]) {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}
