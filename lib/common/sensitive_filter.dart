class SensitiveFilter {
  static const _sensitivePatterns = [
    'dler.cloud',
    'raw.dler.io',
  ];
  
  static bool containsSensitiveInfo(String text) {
    final lowerText = text.toLowerCase();
    return _sensitivePatterns.any((pattern) => lowerText.contains(pattern));
  }
}

