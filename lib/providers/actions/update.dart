part of '../action.dart';

@Riverpod(keepAlive: true)
class UpdateAction extends _$UpdateAction {
  @override
  void build() {
    _controller = ref.watch(actionControllerProvider);
  }

  late AppController _controller;

  Future<void> checkUpdate({bool isUser = false}) =>
      _controller.checkUpdate(isUser: isUser);
}

extension InitControllerExt on AppController {
  Future<void> _init() async {
    FlutterError.onError = (details) {
      Future.microtask(() {
        commonPrint.log(
          'exception: ${details.exception} stack: ${details.stack}',
          logLevel: LogLevel.warning,
        );
      });
    };
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      commonPrint.log(
        'platform exception: $error stack: $stack',
        logLevel: LogLevel.error,
      );
      return false;
    };
    updateTray();
    checkUpdate();
    await autoLaunch?.updateStatus(_ref.read(appSettingProvider).autoLaunch);
    final silentLaunch = shouldLaunchSilently(
      enabled: _ref.read(appSettingProvider).silentLaunch,
      arguments: globalState.launchArguments,
    );
    if (!silentLaunch) {
      await window?.show();
    } else {
      await window?.hide();
    }
    await _handleFailedPreference();
    final bootAttempt = await startupRecovery.begin(
      profileId: _ref.read(currentProfileIdProvider),
      version:
          '${globalState.packageInfo.version}+${globalState.packageInfo.buildNumber}',
      processId: pid,
    );
    if (!startupRecovery.isCurrent(bootAttempt)) return;
    try {
      await _connectCore();
      if (!startupRecovery.isCurrent(bootAttempt)) return;
      await _initCore();
      if (!startupRecovery.isCurrent(bootAttempt)) return;
      await _initStatus();
      if (!startupRecovery.isCurrent(bootAttempt)) return;
      _ref.read(initProvider.notifier).value = true;
      await startupRecovery.markRunning(bootAttempt);
    } catch (_) {
      await startupRecovery.markFailed(bootAttempt);
      rethrow;
    }
    if (startupRecovery.automaticSetupPaused) {
      await window?.show();
      await globalState.showMessage(
        title: appLocalizations.startupRecoveryTitle,
        message: TextSpan(text: appLocalizations.startupRecoveryTip),
        cancelable: false,
      );
    }
  }

  Future<void> _handleFailedPreference() async {
    if (await preferences.isInit) {
      return;
    }
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      await file.safeDelete();
    }
    await handleExit();
  }

  Future<void> _initStatus() async {
    if (!globalState.needInitStatus) {
      commonPrint.log('init status cancel');
      return;
    }
    commonPrint.log('init status');
    if (system.isAndroid) {
      await globalState.updateStartTime();
    }
    if (startupRecovery.automaticSetupPaused) {
      globalState.needInitStatus = false;
      if (globalState.isStart) {
        await globalState.startUpdateTasks([updateRunTime, updateTraffic]);
      }
      return;
    }
    final hasProfile = _ref.read(currentProfileIdProvider) != null;
    final status = globalState.isStart == true
        ? true
        : _ref.read(appSettingProvider).autoRun && hasProfile;
    if (status == true) {
      await updateStatus(true, isInit: true);
    } else {
      await applyProfile(force: true);
    }
  }

  Future<void> checkUpdate({bool isUser = false}) async {
    if (_checkingUpdate) return;
    _checkingUpdate = true;
    try {
      await _checkUpdate(isUser: isUser);
    } finally {
      _checkingUpdate = false;
    }
  }

  Future<void> _checkUpdate({required bool isUser}) async {
    AppUpdateInfo? updateInfo;
    try {
      updateInfo = await request.checkForUpdate();
    } catch (error) {
      commonPrint.log(
        'check update failed: $error',
        logLevel: LogLevel.warning,
      );
      if (isUser) {
        await globalState.showMessage(
          title: appLocalizations.checkUpdate,
          message: TextSpan(text: appLocalizations.checkUpdateFailed),
          cancelable: false,
        );
      }
      return;
    }
    if (updateInfo == null) {
      if (isUser) {
        await globalState.showMessage(
          title: appLocalizations.checkUpdate,
          message: TextSpan(text: appLocalizations.checkUpdateError),
          cancelable: false,
        );
      }
      return;
    }
    final res = await promptForAppUpdate(
      isUser: isUser,
      showWindow: window?.show,
      prompt: () => globalState.showMessage(
        title: appLocalizations.discovery,
        message: TextSpan(
          text: updateInfo!.releaseNotes ?? appLocalizations.noInfo,
        ),
      ),
    );
    if (res != true) {
      return;
    }
    final downloadUrl = getAppUpdateDownloadUrl(Abi.current());
    await safeRun<void>(
      () => _downloadAppUpdate(downloadUrl),
      title: appLocalizations.checkUpdate,
      silence: !isUser,
    );
  }

  Future<void> _downloadAppUpdate(String? downloadUrl) async {
    if (downloadUrl == null) {
      await _openUpdateDownloadUrl('https://dl.dler.io');
      return;
    }
    final result = await globalState.showCommonDialog<UpdateDownloadResult>(
      dismissible: false,
      child: UpdateDownloadDialog(
        download: (token, onProgress) async {
          final client = createAppUpdateDownloadClient();
          try {
            return await downloadAppUpdate(
              client: client,
              url: downloadUrl,
              fallbackUrls: [getAppUpdateFallbackDownloadUrl(downloadUrl)],
              directory: await appPath.tempDir.future,
              cancelToken: token,
              onProgress: onProgress,
            );
          } finally {
            client.close(force: true);
          }
        },
      ),
    );
    await openAppUpdateDownload(
      result: result,
      openFile: (file) => system.isAndroid
          ? app!.openFile(file.path)
          : launchUrl(
              Uri.file(file.path),
              mode: LaunchMode.externalApplication,
            ),
      openBrowser: () => _openUpdateDownloadUrl(downloadUrl),
      onError: (error) => commonPrint.log(
        'Built-in update download failed: $error',
        logLevel: LogLevel.warning,
      ),
    );
  }

  Future<void> _openUpdateDownloadUrl(String downloadUrl) async {
    if (!await launchUrl(
      Uri.parse(downloadUrl),
      mode: LaunchMode.externalApplication,
    )) {
      throw StateError('Unable to open update download URL');
    }
  }
}
