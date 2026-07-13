import 'package:fl_clash/common/request.dart';
import 'package:test/test.dart';

void main() {
  test('formatRemoteVersion displays only the remote version', () {
    expect(formatRemoteVersion('0.8.94+2026071304'), 'v0.8.94+2026071304');
    expect(formatRemoteVersion('v0.8.94+2026071304'), 'v0.8.94+2026071304');
  });
}
