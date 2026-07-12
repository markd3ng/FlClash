import 'package:fl_clash/features/overwrite/proxy_chain.dart';
import 'package:test/test.dart';

void main() {
  test('raw proxy-chain context excludes provider-expanded nodes', () {
    final context = buildProxyChainRawContext(
      customNodesLabel: 'Custom',
      otherNodesLabel: 'Other',
      rawConfig: {
        'proxies': [
          {'name': 'Node A', 'type': 'ss'},
        ],
        'proxy-providers': {
          'Airport': {'type': 'http'},
        },
        'proxy-groups': [
          {
            'name': 'Proxy',
            'type': 'select',
            'proxies': ['Node A'],
            'use': ['Airport'],
          },
        ],
      },
    );

    final candidates = context.sections
        .expand((section) => section.proxies)
        .toSet();
    expect(candidates, contains('Node A'));
    expect(candidates, isNot(contains('Airport')));
    expect(context.nameScope.targetNames, {'Node A'});
    expect(context.nameScope.dialerNames, {'Node A', 'Proxy'});
  });
}
