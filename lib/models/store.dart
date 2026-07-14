import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:fl_clash/l10n/l10n.dart';

class BillingPeriod {
  final String key;
  final String label;
  final int days;
  final int minutes;
  final double price;
  final int bandwidth;
  final String discountLabel;
  final int discountPercent;
  final double listPrice;
  final double savings;
  final bool enabled;

  const BillingPeriod({
    required this.key,
    required this.label,
    required this.days,
    required this.minutes,
    required this.price,
    required this.bandwidth,
    required this.discountLabel,
    required this.discountPercent,
    required this.listPrice,
    required this.savings,
    required this.enabled,
  });

  factory BillingPeriod.fromJson(Map<dynamic, dynamic> json) {
    return BillingPeriod(
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      days: _asInt(json['days']),
      minutes: _asInt(json['minutes']),
      price: _asDouble(json['price']),
      bandwidth: _asInt(json['bandwidth']),
      discountLabel: json['discount_label']?.toString() ?? '',
      discountPercent: _asInt(json['discount_percent']),
      listPrice: _asDouble(json['list_price']),
      savings: _asDouble(json['savings']),
      enabled: _asBool(json['enabled']),
    );
  }
}

/// 商店套餐（对应面板 /api/v1/shop/list 返回项）
class StorePlan {
  final int id;
  final String name;
  final double price;
  final String content;
  final int bandwidth;
  final String planCode;
  final int planRank;
  final List<String> nodeAccess;
  final int classExpireDays;
  final String defaultBillingPeriod;
  final List<BillingPeriod> billingPeriods;
  final int autoRenew;
  final bool realtimePay;
  final bool isTeamPackage;
  final bool isAnnual;
  final bool supportsAnnual;
  final bool canBuy;
  final bool canUpgradeTo;
  final int inventory;
  final List<String> tags;

  const StorePlan({
    required this.id,
    required this.name,
    required this.price,
    required this.content,
    required this.bandwidth,
    required this.planCode,
    required this.planRank,
    required this.nodeAccess,
    required this.classExpireDays,
    required this.defaultBillingPeriod,
    required this.billingPeriods,
    required this.autoRenew,
    required this.realtimePay,
    required this.isTeamPackage,
    required this.isAnnual,
    required this.supportsAnnual,
    required this.canBuy,
    required this.canUpgradeTo,
    required this.inventory,
    this.tags = const [],
  });

  bool get soldOut => inventory == 0;

  List<BillingPeriod> get enabledBillingPeriods {
    final enabled = billingPeriods.where((period) => period.enabled).toList();
    return enabled.isEmpty ? billingPeriods : enabled;
  }

  BillingPeriod? get defaultPeriod {
    return enabledBillingPeriods
            .where((period) => period.key == defaultBillingPeriod)
            .firstOrNull ??
        enabledBillingPeriods.firstOrNull;
  }

  factory StorePlan.fromJson(Map<dynamic, dynamic> json) {
    final legacyClass = _asInt(json['class']);
    final stablePlanCode = json['plan_code']?.toString();
    final planCode = stablePlanCode ?? _legacyPlanCode(legacyClass);
    final periods = _asMapList(
      json['billing_periods'],
    ).map(BillingPeriod.fromJson).toList();
    final isAnnual = _asBool(json['is_annual']);
    return StorePlan(
      id: _asInt(json['id']),
      name: json['name']?.toString() ?? '',
      price: _asDouble(json['price']),
      content: json['content']?.toString() ?? '',
      bandwidth: _asInt(json['bandwidth']),
      planCode: planCode,
      planRank: json['plan_rank'] != null
          ? _asInt(json['plan_rank'])
          : _planRank(planCode) ?? _legacyPlanRank(legacyClass),
      nodeAccess: _asStringList(json['node_access']),
      classExpireDays: _asInt(json['class_expire_days']),
      defaultBillingPeriod: json['default_billing_period']?.toString() ?? '',
      billingPeriods: periods,
      autoRenew: _asInt(json['auto_renew']),
      realtimePay: _asBool(json['realtime_pay']),
      isTeamPackage: _asBool(json['is_team_package']),
      isAnnual: isAnnual,
      supportsAnnual: _asBool(json['supports_annual']) || isAnnual,
      canBuy: _asBool(json['can_buy']),
      canUpgradeTo: _asBool(json['can_upgrade_to']),
      inventory: _asInt(json['inventory']),
      tags: _asStringList(json['tags']),
    );
  }
}

/// 购买记录（对应 /api/v1/shop/bought 返回项）
class BoughtRecord {
  final int id;
  final int shopId;
  final String shopName;
  final String planCode;
  final int? planRank;
  final double buyPrice;
  final double renewPrice;
  final int bandwidth;
  final String coupon;
  final bool autoRenew;
  final int renewState;
  final int status;
  final String buyTime;
  final String billingPeriod;
  final String billingPeriodText;
  final int durationMinutes;
  final bool canUpgrade;
  final bool canActivate;
  final bool canToggleRenew;
  final bool canEarlyRenew;
  final bool canRefund;
  final List<int> upgradeShopIds;

  const BoughtRecord({
    required this.id,
    required this.shopId,
    required this.shopName,
    required this.planCode,
    required this.planRank,
    required this.buyPrice,
    required this.renewPrice,
    required this.bandwidth,
    required this.coupon,
    required this.autoRenew,
    required this.renewState,
    required this.status,
    required this.buyTime,
    required this.billingPeriod,
    required this.billingPeriodText,
    required this.durationMinutes,
    required this.canUpgrade,
    required this.canActivate,
    required this.canToggleRenew,
    required this.canEarlyRenew,
    required this.canRefund,
    required this.upgradeShopIds,
  });

  bool get isActive => status == 1;
  bool get isPending => status == 0;
  bool get isExpired => status == -1;

  factory BoughtRecord.fromJson(Map<dynamic, dynamic> json) {
    return BoughtRecord(
      id: _asInt(json['id']),
      shopId: _asInt(json['shop_id']),
      shopName: json['shop_name']?.toString() ?? '',
      planCode: json['plan_code']?.toString() ?? '',
      planRank: json['plan_rank'] == null ? null : _asInt(json['plan_rank']),
      buyPrice: _asDouble(json['buy_price']),
      renewPrice: _asDouble(json['renew_price']),
      bandwidth: _asInt(json['bandwidth']),
      coupon: json['coupon']?.toString() ?? '',
      autoRenew: _asBool(json['auto_renew']),
        renewState: json['renew_state'] == null
          ? (_asBool(json['auto_renew']) ? 1 : 0)
          : _asInt(json['renew_state']),
      status: _asInt(json['status']),
      buyTime: json['buy_time']?.toString() ?? '',
      billingPeriod: json['billing_period']?.toString() ?? '',
      billingPeriodText: json['billing_period_text']?.toString() ?? '',
      durationMinutes: _asInt(json['duration_minutes']),
      canUpgrade: _asBool(json['can_upgrade']),
        canActivate: json['can_activate'] == null
          ? _asInt(json['status']) == 0
          : _asBool(json['can_activate']),
        canToggleRenew: _asBool(json['can_toggle_renew']),
        canEarlyRenew: json['can_early_renew'] == null
          ? _asInt(json['status']) != -1 && _asBool(json['auto_renew'])
          : _asBool(json['can_early_renew']),
        canRefund: _asBool(json['can_refund']),
      upgradeShopIds: _asIntList(json['upgrade_shop_ids']),
    );
  }
}

/// 支付方式（对应 /api/v1/pay/methods 返回项）
class PaymentMethodOption {
  final String payment;
  final String type;
  final String name;
  final double min;
  final double max;

  const PaymentMethodOption({
    required this.payment,
    required this.type,
    required this.name,
    required this.min,
    required this.max,
  });

  bool get isCrypto =>
      payment == 'cryptapi' ||
      payment.startsWith('usdt_') ||
      type == 'cryptapi' ||
      type.startsWith('usdt_');

  factory PaymentMethodOption.fromJson(Map<dynamic, dynamic> json) {
    return PaymentMethodOption(
      payment: json['payment']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      min: _asDouble(json['min']),
      max: _asDouble(json['max']),
    );
  }
}

enum PaymentInitiationKind { cryptoAddress, externalUrl, balanceDone, error }

/// 统一的发起支付结果，兼容 Cryptapi(result.address)、USDT(qrcode/url+tradeno)、
/// Futoon/alpha(url/qrcode 或 302 跳转) 三种网关返回。
class PaymentInitiation {
  final PaymentInitiationKind kind;
  final String? address;
  final String? amountText;
  final String? coin;
  final String? url;
  final bool renderQrcode;
  final String? pid;
  final String? message;

  const PaymentInitiation({
    required this.kind,
    this.address,
    this.amountText,
    this.coin,
    this.url,
    this.renderQrcode = false,
    this.pid,
    this.message,
  });

  static PaymentInitiation parse(
    dynamic data, {
    int? statusCode,
    String? redirectLocation,
  }) {
    if (statusCode == 302 &&
        redirectLocation != null &&
        redirectLocation.isNotEmpty) {
      return PaymentInitiation(
        kind: PaymentInitiationKind.externalUrl,
        url: redirectLocation,
      );
    }

    dynamic decoded = data;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {}
    }
    if (decoded is! Map) {
      return PaymentInitiation(
        kind: PaymentInitiationKind.error,
        message: AppLocalizations.current.paymentUnknownResponse,
      );
    }

    final ret = _asInt(decoded['ret']);
    final result = decoded['result'];

    // Cryptapi：result.address
    if (result is Map && result['address'] != null) {
      return PaymentInitiation(
        kind: PaymentInitiationKind.cryptoAddress,
        address: result['address']?.toString(),
        amountText: result['amount']?.toString(),
        coin: result['coin']?.toString(),
        pid: result['pid']?.toString(),
      );
    }

    final rawUrl = (decoded['url'] ?? decoded['qrcode'])?.toString();
    if (rawUrl != null && rawUrl.isNotEmpty) {
      final pid = decoded['tradeno']?.toString();
      final amount = decoded['amount']?.toString();
      final render =
          decoded['render_qrcode'] == true ||
          decoded['render_qrcode'] == 'true';
      final isAddress =
          !(rawUrl.startsWith('http://') || rawUrl.startsWith('https://'));
      if (isAddress) {
        // USDT 链上地址
        return PaymentInitiation(
          kind: PaymentInitiationKind.cryptoAddress,
          address: rawUrl,
          amountText: amount,
          coin: 'USDT',
          pid: pid,
        );
      }
      return PaymentInitiation(
        kind: PaymentInitiationKind.externalUrl,
        url: rawUrl,
        amountText: amount,
        pid: pid,
        renderQrcode: render,
      );
    }

    if (ret == 200) {
      return PaymentInitiation(
        kind: PaymentInitiationKind.balanceDone,
        message:
            decoded['msg']?.toString() ??
            AppLocalizations.current.operationSuccess,
      );
    }

    final msg = (decoded['errmsg'] ?? decoded['msg'] ?? decoded['message'])
        ?.toString();
    return PaymentInitiation(
      kind: PaymentInitiationKind.error,
      message: msg ?? AppLocalizations.current.paymentRequestFailed,
    );
  }
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

double _asDouble(dynamic v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

bool _asBool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v?.toString().toLowerCase();
  return s == '1' || s == 'true' || s == 'yes';
}

List<String> _asStringList(dynamic v) {
  if (v is List) {
    return v
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return const [];
}

List<int> _asIntList(dynamic v) {
  if (v is List) return v.map(_asInt).toList();
  return const [];
}

List<Map<dynamic, dynamic>> _asMapList(dynamic value) {
  if (value is! List) return const [];
  return value.whereType<Map>().toList();
}

String _legacyPlanCode(int legacyClass) => switch (legacyClass) {
  1 => 'iron',
  2 => 'alu',
  3 => 'bronze',
  4 => 'silver',
  5 => 'gold',
  6 => 'platinum',
  7 => 'developer',
  8 => 'team',
  9 => 'enterprise',
  10 => 'realtime',
  11 => 'titanium',
  _ => 'no_plan',
};

int? _planRank(String planCode) => switch (planCode.toLowerCase()) {
  'no_plan' => 0,
  'iron' => 10,
  'alu' => 20,
  'bronze' => 30,
  'silver' => 40,
  'gold' => 50,
  'platinum' => 60,
  'diamond' || 'developer' => 70,
  'team' => 80,
  'enterprise' => 90,
  'realtime' => 100,
  'titanium' => 110,
  _ => null,
};

int _legacyPlanRank(int legacyClass) => switch (legacyClass) {
  1 => 10,
  2 => 20,
  3 => 30,
  4 => 40,
  5 => 50,
  6 => 60,
  7 => 70,
  8 => 80,
  9 => 90,
  10 => 100,
  11 => 110,
  _ => 0,
};
