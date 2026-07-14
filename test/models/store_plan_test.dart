import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  group('oixCloud plan contract', () {
    test('stable plan identity wins over legacy class', () {
      final plan = StorePlan.fromJson({
        'id': 12,
        'name': 'Pass Alu',
        'class': 9,
        'plan_code': 'alu',
        'plan_rank': 20,
        'node_access': ['edge', 'cia', 'ixp'],
        'default_billing_period': 'quarterly',
        'billing_periods': [
          {
            'key': 'monthly',
            'label': '月付',
            'days': 30,
            'minutes': 43200,
            'price': 10,
            'bandwidth': 100,
            'enabled': true,
          },
          {
            'key': 'quarterly',
            'label': '季付',
            'days': 90,
            'minutes': 129600,
            'price': 27,
            'bandwidth': 280,
            'discount_label': '9折',
            'discount_percent': 10,
            'list_price': 30,
            'savings': 3,
            'enabled': true,
          },
          {
            'key': 'semiannual',
            'label': '半年付',
            'days': 180,
            'minutes': 259200,
            'price': 50,
            'enabled': true,
          },
          {
            'key': 'yearly',
            'label': '年付',
            'days': 365,
            'minutes': 525600,
            'price': 90,
            'enabled': true,
          },
        ],
        'supports_annual': 1,
        'inventory': 3,
      });

      expect(plan.planCode, 'alu');
      expect(plan.planRank, 20);
      expect(plan.nodeAccess, ['edge', 'cia', 'ixp']);
      expect(plan.enabledBillingPeriods.map((period) => period.key), [
        'monthly',
        'quarterly',
        'semiannual',
        'yearly',
      ]);
      expect(plan.defaultPeriod?.key, 'quarterly');
      expect(plan.defaultPeriod?.price, 27);
      expect(plan.defaultPeriod?.bandwidth, 280);
      expect(plan.defaultPeriod?.discountLabel, '9折');
      expect(plan.defaultPeriod?.discountPercent, 10);
      expect(plan.defaultPeriod?.listPrice, 30);
      expect(plan.defaultPeriod?.savings, 3);
      expect(plan.supportsAnnual, true);
    });

    test('legacy class is converted only at decode boundary', () {
      final plan = StorePlan.fromJson({
        'id': 2,
        'name': 'Pass Bronze',
        'class': 2,
      });

      expect(plan.planCode, 'alu');
      expect(plan.planRank, 20);
    });

    test('stable code supplies rank before legacy class fallback', () {
      final fromCode = StorePlan.fromJson({
        'id': 1,
        'plan_code': 'bronze',
        'class': 2,
      });
      final explicitZero = StorePlan.fromJson({
        'id': 2,
        'plan_code': 'iron',
        'plan_rank': 0,
        'class': 2,
      });

      expect(fromCode.planCode, 'bronze');
      expect(fromCode.planRank, 30);
      expect(explicitZero.planRank, 0);
    });

    test('legacy special classes keep their old server identity', () {
      final developer = StorePlan.fromJson({'id': 7, 'class': 7});
      final enterprise = StorePlan.fromJson({'id': 9, 'class': 9});
      final realtime = StorePlan.fromJson({'id': 10, 'class': 10});

      expect(developer.planCode, 'developer');
      expect(developer.planRank, 70);
      expect(enterprise.planCode, 'enterprise');
      expect(enterprise.planRank, 90);
      expect(realtime.planCode, 'realtime');
      expect(realtime.planRank, 100);
    });

    test('bought record exposes exact upgrade targets and billing period', () {
      final bought = BoughtRecord.fromJson({
        'id': 8,
        'shop_id': 12,
        'plan_code': 'alu',
        'plan_rank': 20,
        'billing_period': 'quarterly',
        'billing_period_text': '季付',
        'duration_minutes': 129600,
        'upgrade_shop_ids': [20, '21'],
      });

      expect(bought.planCode, 'alu');
      expect(bought.planRank, 20);
      expect(bought.billingPeriod, 'quarterly');
      expect(bought.billingPeriodText, '季付');
      expect(bought.durationMinutes, 129600);
      expect(bought.upgradeShopIds, [20, 21]);
    });

    test('bought rank distinguishes explicit zero from missing', () {
      final explicitZero = BoughtRecord.fromJson({
        'id': 1,
        'shop_id': 1,
        'plan_rank': 0,
      });
      final missing = BoughtRecord.fromJson({'id': 2, 'shop_id': 1});

      expect(explicitZero.planRank, 0);
      expect(missing.planRank, isNull);
    });
  });

  group('oixCloud subscription tier', () {
    test('legacy no-plan display name stays unprivileged', () {
      expect(SubscriptionTier.fromServer('no plan'), SubscriptionTier.none);
    });

    test('editable options keep routing and arbitrary extras', () {
      final params = OixParams.parse(
        '&lv=2&type=love&tfo=false&simplerules=true&area=hk&custom=1',
      );

      expect(
        params.encodeEditableOptions(),
        '&lv=2&type=love&area=hk&custom=1',
      );
      expect(params.tfo, false);
      expect(params.simplerules, true);
      expect(params.extras, {'area': 'hk', 'custom': '1'});
    });

    test('encoded options round trip without double encoding', () {
      final params = OixParams.parse('&space=a%20b&plus=a+b&ampersand=a%26b');
      final encoded = params.encodeEditableOptions();

      expect(params.extras, {
        'space': 'a b',
        'plus': 'a b',
        'ampersand': 'a&b',
      });
      expect(OixParams.parse(encoded), params);
      expect(encoded, isNot(contains('%2520')));
      expect(encoded, contains('ampersand=a%26b'));
    });

    test('invalid and bare reserved keys never become extras', () {
      final params = OixParams.parse(
        '&lv=bad&LV=bad&type=love&type&tfo=bad&tfo&simplerules&area=hk',
      );

      expect(params.level, isNull);
      expect(params.type, 'love');
      expect(params.tfo, isNull);
      expect(params.simplerules, false);
      expect(params.extras, {'area': 'hk'});
      expect(params.encode(), '&type=love&area=hk');
    });

    test('tier migration preserves switches and arbitrary extras', () {
      final params = OixParams.parse(
        '&lv=1&tfo=false&simplerules=true&area=hk',
      );
      final migrated = params.applyingTierDefaults(
        SubscriptionTier.premium.defaultParams,
      );

      expect(params.encodeDefaultComparable(), '&lv=1');
      expect(migrated.level, isNull);
      expect(migrated.type, 'love');
      expect(migrated.tfo, false);
      expect(migrated.simplerules, true);
      expect(migrated.extras, {'area': 'hk'});
    });

    test('uses plan rank before display name', () {
      expect(
        SubscriptionTier.fromServer(
          'Pass Bronze',
          planCode: 'iron',
          planRank: 10,
        ),
        SubscriptionTier.none,
      );
      expect(
        SubscriptionTier.fromServer(
          'arbitrary label',
          planCode: 'alu',
          planRank: 20,
        ),
        SubscriptionTier.alu,
      );
      expect(
        SubscriptionTier.fromServer(
          'Pass Iron',
          planCode: 'bronze',
          planRank: 30,
        ),
        SubscriptionTier.premium,
      );

      expect(SubscriptionTier.none.defaultParams.encode(), '');
      expect(SubscriptionTier.alu.defaultParams.encode(), '&lv=2');
      expect(SubscriptionTier.premium.defaultParams.encode(), '&type=love');
    });

    test('old cached profile defaults new identity fields', () {
      final profile = CloudProfile.fromJson({
        'subscription': 'Pass Bronze',
        'expireTime': '2026-08-01T00:00:00.000Z',
        'todayUsed': '0 B',
        'totalUsed': '0 B',
        'totalTraffic': '1 GB',
        'usageProgress': 0.0,
        'remaining': '1 GB',
        'balance': '0.00',
        'commission': '0.00',
        'points': '0',
      });

      expect(profile.planCode, '');
      expect(profile.planRank, isNull);
      expect(profile.nodeAccess, isEmpty);
      expect(
        SubscriptionTier.fromServer(
          profile.subscription,
          planCode: profile.planCode,
          planRank: profile.planRank,
        ),
        SubscriptionTier.alu,
      );
    });

    test('old Default cache stays unprivileged', () {
      expect(SubscriptionTier.fromServer('Default'), SubscriptionTier.none);
    });

    test('explicit zero rank wins over plan code', () {
      expect(
        SubscriptionTier.fromServer('Pass Iron', planCode: 'iron', planRank: 0),
        SubscriptionTier.none,
      );
    });
  });
}
