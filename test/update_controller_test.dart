import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/widgets/update_download_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic update prompt keeps a silent launch hidden', () async {
    var prompted = false;
    final result = await promptForAppUpdate(
      isUser: false,
      showWindow: () async =>
          fail('background checks must not show the window'),
      prompt: () async {
        prompted = true;
        return true;
      },
    );
    expect(prompted, isTrue);
    expect(result, isTrue);
  });

  test('manual update waits for the window before prompting', () async {
    final shown = Completer<void>();
    final events = <String>[];
    final result = promptForAppUpdate(
      isUser: true,
      showWindow: () {
        events.add('show');
        return shown.future;
      },
      prompt: () async {
        events.add('prompt');
        return false;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, ['show']);
    shown.complete();
    expect(await result, isFalse);
    expect(events, ['show', 'prompt']);
  });

  test('mobile update prompts without a desktop window', () async {
    expect(
      await promptForAppUpdate(
        isUser: true,
        showWindow: null,
        prompt: () async => null,
      ),
      isNull,
    );
  });

  test('update installers match every supported platform and ABI', () {
    const installers = {
      Abi.windowsX64: 'windows-amd64-setup.exe',
      Abi.windowsArm64: 'windows-arm64-setup.exe',
      Abi.macosX64: 'macos-amd64.dmg',
      Abi.macosArm64: 'macos-arm64.dmg',
      Abi.androidArm: 'android-armeabi-v7a.apk',
      Abi.androidArm64: 'android-arm64-v8a.apk',
      Abi.androidX64: 'android-x86_64.apk',
      Abi.linuxX64: 'linux-amd64.deb',
      Abi.linuxArm64: 'linux-arm64.deb',
    };
    for (final entry in installers.entries) {
      final downloadUrl = getAppUpdateDownloadUrl(entry.key);
      expect(
        downloadUrl,
        'https://dl.dler.io/flclash-${entry.value}',
        reason: entry.key.toString(),
      );
      expect(
        getAppUpdateFallbackDownloadUrl(downloadUrl!),
        'https://github.com/$releaseRepository/releases/latest/download/'
        'flclash-${entry.value}',
        reason: entry.key.toString(),
      );
    }
    for (final abi in Abi.values.where((abi) => !installers.containsKey(abi))) {
      expect(getAppUpdateDownloadUrl(abi), isNull, reason: abi.toString());
    }
  });

  test('cancelled download never opens a file or browser', () async {
    await openAppUpdateDownload(
      result: null,
      openFile: (_) async => fail('must not open an installer'),
      openBrowser: () async => fail('must not open the browser'),
      onError: (_) => fail('cancellation is not a download error'),
    );
  });

  test('successful installer open does not fall back to browser', () async {
    final file = File('/tmp/update.apk');
    await openAppUpdateDownload(
      result: UpdateDownloadResult.success(file),
      openFile: (value) async {
        expect(value, same(file));
        return true;
      },
      openBrowser: () async => fail('must not open the browser'),
      onError: (_) => fail('must not report an error'),
    );
  });

  test(
    'failed download falls back without attempting to open a file',
    () async {
      final error = StateError('download failed');
      var browserOpens = 0;
      await openAppUpdateDownload(
        result: UpdateDownloadResult.failure(error),
        openFile: (_) async => fail('must not open an installer'),
        openBrowser: () async => browserOpens++,
        onError: (value) => expect(value, same(error)),
      );
      expect(browserOpens, 1);
    },
  );

  for (final throws in [false, true]) {
    test(
      'installer open ${throws ? 'throwing' : 'returning false'} falls back',
      () async {
        final error = StateError('installer unavailable');
        var browserOpens = 0;
        var errors = 0;
        await openAppUpdateDownload(
          result: UpdateDownloadResult.success(File('/tmp/update.apk')),
          openFile: (_) async {
            if (throws) throw error;
            return false;
          },
          openBrowser: () async => browserOpens++,
          onError: (value) {
            errors++;
            if (throws) expect(value, same(error));
          },
        );
        expect(browserOpens, 1);
        expect(errors, 1);
      },
    );
  }

  test(
    'browser failure propagates without retrying the download or browser',
    () async {
      final error = StateError('browser unavailable');
      var browserOpens = 0;
      await expectLater(
        openAppUpdateDownload(
          result: UpdateDownloadResult.failure(StateError('download failed')),
          openFile: (_) async => fail('must not open an installer'),
          openBrowser: () async {
            browserOpens++;
            throw error;
          },
          onError: (_) {},
        ),
        throwsA(same(error)),
      );
      expect(browserOpens, 1);
    },
  );
}
