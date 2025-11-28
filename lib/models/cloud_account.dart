class CloudCredentials {
  final String accessToken;
  final String? tokenExpire;
  
  const CloudCredentials({
    required this.accessToken,
    this.tokenExpire,
  });
  
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
      throw NoPlanException();
    }
    
    return CloudProfile(
      subscription: plan as String,
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

  static double _parseTraffic(String traffic) {
    final regex = RegExp(r'([\d.]+)\s*([KMGT]i?B)', caseSensitive: false);
    final match = regex.firstMatch(traffic);
    if (match == null) return 0.0;
    
    final value = double.tryParse(match.group(1) ?? '0') ?? 0.0;
    final unit = (match.group(2) ?? 'B').toUpperCase();
    
    const multipliers = {
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
    
    return value * (multipliers[unit] ?? 1.0);
  }
}

class CloudConfigInfo {
  final String downloadUrl;
  final String profileName;
  
  const CloudConfigInfo({
    required this.downloadUrl,
    required this.profileName,
  });
  
  String get fullUrl => downloadUrl;
  
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
  final bool isPinned;
  
  const CloudNotification({
    required this.message,
    required this.publishTime,
    this.isPinned = false,
  });
  
  Map<String, dynamic> toMap() => {
    'content': message,
    'date': publishTime.toIso8601String(),
  };
  
  factory CloudNotification.fromApiResponse(Map<String, dynamic> data) {
    return CloudNotification(
      message: data['content'] as String? ?? '',
      publishTime: _parsePublishTime(data['date'] as String?),
      isPinned: false,
    );
  }
  
  static DateTime _parsePublishTime(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return DateTime.now();
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      return DateTime.now();
    }
  }

  String get cleanMessage {
    return message
        .replaceAll(RegExp(r'<p[^>]*>'), '\n')
        .replaceAll(RegExp(r'</p>'), '\n')
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<hr\s*/?>'), '\n${'─' * 40}\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim()
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }
}

class NoPlanException implements Exception {
  const NoPlanException();
}

