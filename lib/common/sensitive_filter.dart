import 'package:fl_clash/common/common.dart';

class SensitiveFilter {
  static const _sensitivePatterns = [
    secrets.OIX_API_DOMAIN,
    'raw.dler.io',
  ];
  
  static bool containsSensitiveInfo(String text) {
    final lowerText = text.toLowerCase();
    return _sensitivePatterns.any((pattern) => lowerText.contains(pattern));
  }
}

