import 'package:fl_clash/common/http.dart';
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

  test('managed config uses the running core proxy only when ready', () {
    expect(
      resolveManagedConfigProxy(
        isCoreRunning: true,
        hasProxyGroups: true,
        port: 7890,
      ),
      'PROXY localhost:7890; DIRECT',
    );

    for (final state in [
      (running: false, groups: true, port: 7890),
      (running: true, groups: false, port: 7890),
      (running: true, groups: true, port: 0),
    ]) {
      expect(
        resolveManagedConfigProxy(
          isCoreRunning: state.running,
          hasProxyGroups: state.groups,
          port: state.port,
        ),
        'DIRECT',
      );
    }
  });
}
