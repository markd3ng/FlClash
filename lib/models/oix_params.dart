enum SubscriptionTier {
  none,
  alu,
  premium;

  static SubscriptionTier fromServer(
    String? raw, {
    String? planCode,
    int? planRank,
    List<String>? nodeAccess,
  }) {
    final access =
        nodeAccess
            ?.map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .toSet() ??
        const <String>{};
    if (access.isNotEmpty) {
      if (access.any(
        const {'fusion', 'fusion_advanced', 'fusion_premium', 'gia'}.contains,
      )) {
        return premium;
      }
      if (access.contains('cia') || access.contains('ixp')) return alu;
      return none;
    }

    if (planRank != null) {
      if (planRank >= 40) return premium;
      if (planRank >= 20) return alu;
      return none;
    }

    switch (planCode?.trim().toLowerCase()) {
      case 'alu':
      case 'bronze':
        return alu;
      case 'silver':
      case 'gold':
      case 'platinum':
      case 'diamond':
      case 'developer':
      case 'team':
      case 'enterprise':
      case 'realtime':
      case 'titanium':
        return premium;
      case 'no_plan':
      case 'iron':
        return none;
    }

    final s = raw?.trim().toLowerCase() ?? '';
    if (s.isEmpty || s == 'null' || s == 'no plan' || s == 'default') {
      return none;
    }
    if (s == 'pass iron') return none;
    if (s == 'pass alu' || s == 'pass bronze') return alu;
    return premium;
  }

  bool get canUseEmergency => this == premium;

  CloudParams get defaultParams => switch (this) {
    none => const CloudParams(),
    alu => const CloudParams(level: NetworkLevel.emergency),
    premium => const CloudParams(type: 'love'),
  };
}

enum NetworkLevel {
  overseas('overseas'),
  emergency('emergency');

  final String value;
  const NetworkLevel(this.value);

  static NetworkLevel? fromValue(String? v) {
    for (final lv in NetworkLevel.values) {
      if (lv.value == v) return lv;
    }
    return null;
  }

  static NetworkLevel? fromLegacyValue(String? value) => switch (value) {
    '1' => overseas,
    '2' => emergency,
    _ => null,
  };
}

class CloudParams {
  final NetworkLevel? level;
  final String? type;
  final bool? tfo;
  final bool simplerules;
  final Map<String, String> extras;

  const CloudParams({
    this.level,
    this.type,
    this.tfo,
    this.simplerules = false,
    this.extras = const {},
  });

  static CloudParams parse(String raw) {
    final cleaned = raw.startsWith('&') ? raw.substring(1) : raw;
    if (cleaned.isEmpty) return const CloudParams();

    NetworkLevel? level;
    String? type;
    bool? tfo;
    bool simplerules = false;
    final extras = <String, String>{};

    for (final pair in cleaned.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq < 0) {
        final key = _decodeQueryComponent(pair);
        if (!_isReservedKey(key)) extras[key] = '';
        continue;
      }
      final k = _decodeQueryComponent(pair.substring(0, eq));
      final v = _decodeQueryComponent(pair.substring(eq + 1));
      switch (k.toLowerCase()) {
        case 'mode':
          level = NetworkLevel.fromValue(v) ?? level;
        case 'lv':
          level ??= NetworkLevel.fromLegacyValue(v);
        case 'type':
          type = _normalizePremiumType(v) ?? type;
        case 'tfo':
          if (v == 'true') tfo = true;
          if (v == 'false') tfo = false;
        case 'simplerules':
          simplerules = v == 'true';
        default:
          if (!_isReservedKey(k)) extras[k] = v;
      }
    }

    if (level != null) type = null;

    return CloudParams(
      level: level,
      type: type,
      tfo: tfo,
      simplerules: simplerules,
      extras: extras,
    );
  }

  String encode() {
    final segments = <String>[];
    if (level != null) segments.add('mode=${level!.value}');
    final premiumType = _normalizePremiumType(type);
    if (level == null && premiumType != null) {
      segments.add('type=$premiumType');
    }
    if (tfo != null) segments.add('tfo=$tfo');
    if (simplerules) segments.add('simplerules=true');
    extras.forEach((k, v) {
      if (k.isEmpty || _isReservedKey(k)) return;
      final encodedKey = Uri.encodeQueryComponent(k);
      final encodedValue = Uri.encodeQueryComponent(v);
      segments.add(v.isEmpty ? encodedKey : '$encodedKey=$encodedValue');
    });
    if (segments.isEmpty) return '';
    return '&${segments.join('&')}';
  }

  /// URL-suffix form guaranteed to include a `tfo` segment (defaults to true).
  /// Used when handing off to the fetcher, which always wants an explicit value.
  String encodeWithTfo() {
    final withTfo = tfo == null ? copyWith(tfo: true) : this;
    return withTfo.encode();
  }

  CloudParams copyWith({
    Object? level = _sentinel,
    Object? type = _sentinel,
    Object? tfo = _sentinel,
    Object? simplerules = _sentinel,
    Map<String, String>? extras,
  }) {
    return CloudParams(
      level: level == _sentinel ? this.level : level as NetworkLevel?,
      type: type == _sentinel ? this.type : type as String?,
      tfo: tfo == _sentinel ? this.tfo : tfo as bool?,
      simplerules: simplerules == _sentinel
          ? this.simplerules
          : simplerules as bool,
      extras: extras ?? this.extras,
    );
  }

  /// Encoded form excluding independent switches. Used to compare with tier
  /// defaults, which only own routing params like level/type.
  String encodeDefaultComparable() =>
      CloudParams(level: level, type: type).encode();

  String encodeEditableOptions() =>
      copyWith(tfo: null, simplerules: false).encode();

  CloudParams applyingTierDefaults(CloudParams defaults) {
    return copyWith(level: defaults.level, type: defaults.type);
  }

  /// Strip emergency mode if the current [tier] cannot support it.
  CloudParams stripEmergencyIfUnsupported(SubscriptionTier tier) {
    if (level == NetworkLevel.emergency && tier == SubscriptionTier.none) {
      return copyWith(level: null);
    }
    return this;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CloudParams) return false;
    if (level != other.level ||
        type != other.type ||
        tfo != other.tfo ||
        simplerules != other.simplerules) {
      return false;
    }
    if (extras.length != other.extras.length) return false;
    for (final e in extras.entries) {
      if (other.extras[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var extrasHash = 0;
    for (final extra in extras.entries) {
      extrasHash ^= Object.hash(extra.key, extra.value);
    }
    return Object.hash(
      level,
      type,
      tfo,
      simplerules,
      extras.length,
      extrasHash,
    );
  }

  static String _decodeQueryComponent(String value) {
    try {
      return Uri.decodeQueryComponent(value);
    } on FormatException {
      return value;
    }
  }

  static bool _isReservedKey(String key) {
    return const {
      'mode',
      'lv',
      'nolv',
      'type',
      'tfo',
      'simplerules',
    }.contains(key.toLowerCase());
  }

  static String? _normalizePremiumType(String? type) {
    final normalized = type?.trim().toLowerCase();
    return const {'love', 'latest', 'extreme'}.contains(normalized)
        ? 'love'
        : null;
  }
}

const _sentinel = Object();
