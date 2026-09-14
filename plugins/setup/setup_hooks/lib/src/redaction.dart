String redactBuildOutput(String value) => value
    .replaceAll(RegExp(r'v2:[A-Za-z0-9+/]+={0,2}'), '<redacted>')
    .replaceAllMapped(
      RegExp(r'(-X\s+main\.GlobalDNSAuth(?:PrivateKey|Domains)=)\S+'),
      (m) => '${m[1]}<redacted>',
    )
    .replaceAllMapped(
      RegExp(
        r'((?:DNS_AUTH_PRIVATE_KEY|DNS_AUTH_DOMAINS|PROFILE_KEY|FLCLASH_APP_SECRET|DART_DEFINES)=)\S+',
      ),
      (m) => '${m[1]}<redacted>',
    );
