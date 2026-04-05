class secrets {
  static const String _oixApiDomain = String.fromEnvironment('OIX_API_DOMAIN');
  static const String OIX_API_DOMAIN =
      _oixApiDomain.isEmpty ? 'oics.net' : _oixApiDomain;

  static const String _apiManagedRouter = String.fromEnvironment(
    'API_MANAGED_ROUTER',
  );
  static const String API_MANAGED_ROUTER =
      _apiManagedRouter.isEmpty ? '/managed/flclash' : _apiManagedRouter;

  static const String PROFILE_KEY = String.fromEnvironment('PROFILE_KEY');
}
