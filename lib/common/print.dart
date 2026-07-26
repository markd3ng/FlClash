import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/common/secrets.dart';
import 'package:flutter/material.dart';

class CommonPrint {
  static CommonPrint? _instance;

  CommonPrint._internal();

  factory CommonPrint() {
    _instance ??= CommonPrint._internal();
    return _instance!;
  }

  void log(String? text, {LogLevel logLevel = LogLevel.info}) {
    final payload = '[APP] ${Secrets.redactApiDomains(text ?? 'null')}';
    final log = Log.app(payload).copyWith(logLevel: logLevel);
    debugPrint(payload);
    appController.writePersistentLog(log);
    if (!appController.isAttach) {
      return;
    }
    appController.addLog(log, persist: false);
  }
}

final commonPrint = CommonPrint();
