import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('delete account request includes confirmation and optional TOTP', () {
    expect(
      buildDeleteAccountRequestData(
        password: 'secret',
        twoFactorCode: ' 123456 ',
      ),
      {'passwd': 'secret', 'confirmation': 'DELETE', 'code': '123456'},
    );

    expect(buildDeleteAccountRequestData(password: 'secret'), {
      'passwd': 'secret',
      'confirmation': 'DELETE',
    });
  });
}
