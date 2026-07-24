import 'package:fl_clash/utils/safe_storage.dart';
import 'package:test/test.dart';

void main() {
  test('legacySecureStorageValue reads a string value', () {
    expect(
      legacySecureStorageValue(
        '{"config_age_seed":"seed","cloud_token":"token"}',
        'cloud_token',
      ),
      'token',
    );
  });

  test('legacySecureStorageValue rejects a non-object payload', () {
    expect(
      () => legacySecureStorageValue('["token"]', 'cloud_token'),
      throwsFormatException,
    );
  });
}
