import 'package:fl_clash/common/update_download_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final appUpdateDownloadProvider = Provider<AppUpdateDownloadTask>((ref) {
  final task = AppUpdateDownloadTask();
  ref.onDispose(task.dispose);
  return task;
});
