class Secrets {
  const Secrets._();

  static const String profileKey = String.fromEnvironment('PROFILE_KEY');

  static const String baseDomain = String.fromEnvironment('BASE_DOMAIN');
  static const String spareDomain = String.fromEnvironment('SPARE_DOMAIN');
  static const String apiDomain = String.fromEnvironment('API_DOMAIN');
  static const String spareApiDomain = String.fromEnvironment(
    'SPARE_API_DOMAIN',
  );

  static const String flClashAppSecret = String.fromEnvironment(
    'FLCLASH_APP_SECRET',
  );

  static String get primarySiteDomain => baseDomain.trim();

  static String get spareSiteDomain => spareDomain.trim();

  static String get primaryApiDomain => _requireDomain(apiDomain, 'API_DOMAIN');

  static String get fallbackApiDomain =>
      _requireDomain(spareApiDomain, 'SPARE_API_DOMAIN');

  static List<String> get apiDomains => {
    primaryApiDomain.toLowerCase(),
    fallbackApiDomain.toLowerCase(),
  }.toList();

  static bool isApiDomain(String host) {
    return apiDomains.contains(host.trim().toLowerCase());
  }

  static String _requireDomain(String value, String name) {
    final domain = value.trim();
    if (domain.isEmpty) {
      throw StateError('$name must be configured');
    }
    return domain;
  }
}
