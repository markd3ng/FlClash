import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/services/age_crypto.dart';
import 'package:fl_clash/services/config_key_store.dart';
import 'package:fl_clash/services/durable_config_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late AgeIdentity identity;
  late DurableConfigStore store;

  setUpAll(() async {
    identity = await AgeCrypto.identityFromSeed(
      List<int>.generate(32, (i) => i),
    );
    store = DurableConfigStore(identityProvider: () async => identity);
  });

  test('encrypted config round-trips and is not plaintext', () async {
    final directory = await Directory.systemTemp.createTemp('config_store_');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'config.age');
    final value = {
      'davProps': {'password': 'secret'},
      'version': 3,
    };

    await store.write(path, value);

    expect(await store.read(path), value);
    expect(
      utf8.decode(await File(path).readAsBytes()),
      isNot(contains('secret')),
    );
  });

  test('invalid target recovers from a valid old candidate', () async {
    final directory = await Directory.systemTemp.createTemp('config_store_');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'config.age');
    final old = File('$path.old');
    final value = {'value': 'old'};
    await store.write(path, value);
    await File(path).rename(old.path);
    await File(path).writeAsString('invalid');

    expect(await store.read(path), value);
    expect(await File(path).exists(), true);
    expect(await old.exists(), false);
  });

  test('clear removes target and recovery candidates', () async {
    final directory = await Directory.systemTemp.createTemp('config_store_');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'config.age');
    for (final suffix in ['', '.tmp', '.old']) {
      await File('$path$suffix').writeAsString('data');
    }

    await store.clear(path);

    for (final suffix in ['', '.tmp', '.old']) {
      expect(await File('$path$suffix').exists(), false);
    }
  });

  test(
    'identity provider failure makes encrypted config unavailable',
    () async {
      final directory = await Directory.systemTemp.createTemp('config_store_');
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'config.age');
      await File(path).writeAsString('encrypted');
      final unavailableStore = DurableConfigStore(
        identityProvider: () => throw StateError('invalid seed'),
      );

      expect(await unavailableStore.read(path), isNull);
    },
  );

  test('config seed accepts only canonical 32-byte base64', () {
    final valid = base64Encode(List<int>.generate(32, (index) => index));

    expect(ConfigKeyStore.decodeSeed(valid), hasLength(32));
    expect(ConfigKeyStore.decodeSeed('not-base64'), isNull);
    expect(
      ConfigKeyStore.decodeSeed(base64Encode(List<int>.filled(31, 0))),
      isNull,
    );
    expect(ConfigKeyStore.decodeSeed('$valid\n'), isNull);
  });
}
