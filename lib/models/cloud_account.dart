class CloudCredentials {
  final String accessToken;
  final String? tokenExpire;

  const CloudCredentials({required this.accessToken, this.tokenExpire});

  bool get isExpired {
    if (tokenExpire == null) return false;
    try {
      final expireDate = DateTime.parse(tokenExpire!.replaceAll(' ', 'T'));
      return DateTime.now().isAfter(expireDate);
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toMap() => {
    'access_token': accessToken,
    if (tokenExpire != null) 'token_expire': tokenExpire,
  };

  factory CloudCredentials.fromMap(Map<String, dynamic> map) {
    return CloudCredentials(
      accessToken: map['access_token'] as String,
      tokenExpire: map['token_expire'] as String?,
    );
  }
}

class CloudProfile {
  final String subscription;
  final int level;
  final String expireTime;
  final String todayUsed;
  final String totalUsed;
  final String remaining;
  final String totalTraffic;
  final String balance;
  final String commission;
  final String points;

  const CloudProfile({
    required this.subscription,
    this.level = 0,
    required this.expireTime,
    required this.todayUsed,
    required this.totalUsed,
    required this.remaining,
    required this.totalTraffic,
    required this.balance,
    required this.commission,
    required this.points,
  });

  Map<String, dynamic> toMap() => {
    'plan': subscription,
    'class': level,
    'plan_time': expireTime,
    'today_used': todayUsed,
    'used': totalUsed,
    'unused': remaining,
    'traffic': totalTraffic,
    'money': balance,
    'aff_money': commission,
    'integral': points,
  };

  factory CloudProfile.fromApiResponse(Map<String, dynamic> data) {
    final plan = data['plan'];
    if (plan == null || (plan is String && plan.trim().isEmpty)) {
      throw const NoPlanException();
    }
    
    final planStr = plan as String;
    int calculatedLevel = 0;
    if (planStr == 'null') {
      calculatedLevel = 0;
    } else if (planStr == 'Pass Iron') {
      calculatedLevel = 1;
    } else if (planStr == 'Pass Bronze') {
      calculatedLevel = 2;
    } else {
      calculatedLevel = 3;
    }

    return CloudProfile(
      subscription: planStr,
      level: calculatedLevel,
      expireTime: data['plan_time'] as String,
      todayUsed: data['today_used'] as String,
      totalUsed: data['used'] as String,
      remaining: data['unused'] as String,
      totalTraffic: data['traffic'] as String,
      balance: data['money'] as String,
      commission: data['aff_money'] as String,
      points: data['integral'].toString(),
    );
  }

  double get usageProgress {
    try {
      final usedBytes = _parseTraffic(totalUsed);
      final totalBytes = _parseTraffic(totalTraffic);
      if (totalBytes == 0) return 0.0;
      return (usedBytes / totalBytes).clamp(0.0, 1.0);
    } catch (_) {
      return 0.0;
    }
  }

  static final _trafficRegex = RegExp(
    r'([\d.]+)\s*([KMGT]?i?B)',
    caseSensitive: false,
  );

  static const _trafficMultipliers = {
    'B': 1.0,
    'KB': 1024.0,
    'KIB': 1024.0,
    'MB': 1024.0 * 1024,
    'MIB': 1024.0 * 1024,
    'GB': 1024.0 * 1024 * 1024,
    'GIB': 1024.0 * 1024 * 1024,
    'TB': 1024.0 * 1024 * 1024 * 1024,
    'TIB': 1024.0 * 1024 * 1024 * 1024,
  };

  static double _parseTraffic(String traffic) {
    final match = _trafficRegex.firstMatch(traffic);
    if (match == null) return 0.0;

    final value = double.tryParse(match.group(1) ?? '0') ?? 0.0;
    final unit = (match.group(2) ?? 'B').toUpperCase();
    return value * (_trafficMultipliers[unit] ?? 1.0);
  }
}

class CloudConfigInfo {
  final String downloadUrl;
  final String profileName;

  const CloudConfigInfo({required this.downloadUrl, required this.profileName});

  factory CloudConfigInfo.fromApiResponse(Map<String, dynamic> data) {
    return CloudConfigInfo(
      downloadUrl: data['smart'] as String,
      profileName: data['name'] as String,
    );
  }
}

class CloudNotification {
  final String message;
  final DateTime publishTime;

  const CloudNotification({required this.message, required this.publishTime});

  Map<String, dynamic> toMap() => {
    'content': message,
    'date': publishTime.toIso8601String(),
  };

  factory CloudNotification.fromApiResponse(Map<String, dynamic> data) {
    return CloudNotification(
      message: data['content'] as String? ?? '',
      publishTime: _parseDate(data['date'] as String?),
    );
  }

  static DateTime _parseDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return DateTime.now();
    return DateTime.tryParse(dateStr) ?? DateTime.now();
  }

  static final _htmlTagRegex = RegExp(r'<[^>]+>');
  static final _pOpenRegex = RegExp(r'<p[^>]*>');
  static final _brRegex = RegExp(r'<br\s*/?>');
  static final _hrRegex = RegExp(r'<hr\s*/?>');
  static final _multiNewlineRegex = RegExp(r'\n{3,}');
  static final _separator = '\n${'─' * 40}\n';

  String get cleanMessage {
    return message
        .replaceAll(_pOpenRegex, '\n')
        .replaceAll('</p>', '\n')
        .replaceAll(_brRegex, '\n')
        .replaceAll(_hrRegex, _separator)
        .replaceAll(_htmlTagRegex, '')
        .trim()
        .replaceAll(_multiNewlineRegex, '\n\n');
  }
}

class NoPlanException implements Exception {
  const NoPlanException();
}
