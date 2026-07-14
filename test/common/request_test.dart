import 'package:fl_clash/common/request.dart';
import 'package:test/test.dart';

void main() {
  test('formatRemoteVersion includes package version for a build number', () {
    expect(formatRemoteVersion('2026071413', '0.8.94'), 'v0.8.94+2026071413');
  });
}
