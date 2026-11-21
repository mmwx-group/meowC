import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视觉主题预设：底层卡片均保持清透实底 + 极细描边；iOS 27 液态玻璃强化 Dock 与弹出层（气泡/对话框/菜单）的光学折射与高光描边。
enum MeowVisualPreset {
  crispMist,
  ios27Glass,
  obsidian,
  sakuraAura,
  morandiMist;

  String get label => switch (this) {
    MeowVisualPreset.crispMist => '静谧雾白',
    MeowVisualPreset.ios27Glass => 'iOS 27 液态玻璃',
    MeowVisualPreset.obsidian => '暗夜极客',
    MeowVisualPreset.sakuraAura => '樱雾琉璃',
    MeowVisualPreset.morandiMist => '莫兰迪柔雾',
  };

  String get subtitle => switch (this) {
    MeowVisualPreset.crispMist => '纯净中性雾白与炭黑，高对比细描边',
    MeowVisualPreset.ios27Glass => '实底卡片 + 光学折射 Dock 与液态玻璃弹出层',
    MeowVisualPreset.obsidian => 'OLED 纯黑底色与翡翠青遥测质感',
    MeowVisualPreset.sakuraAura => '轻盈樱粉极光与柔紫点缀',
    MeowVisualPreset.morandiMist => '低饱和莫兰迪灰绿，克制耐看',
  };

  /// 每套预设的推荐主色（预览色块用；实际配色仍可叠加用户的主题色种子）
  Color get previewAccent => switch (this) {
    MeowVisualPreset.crispMist => const Color(0xFFD94B7A),
    MeowVisualPreset.ios27Glass => const Color(0xFFE05288),
    MeowVisualPreset.obsidian => const Color(0xFF10B981),
    MeowVisualPreset.sakuraAura => const Color(0xFFE56B9F),
    MeowVisualPreset.morandiMist => const Color(0xFF5D8A78),
  };

  Color get previewBgLight => switch (this) {
    MeowVisualPreset.crispMist => const Color(0xFFF5F6F8),
    MeowVisualPreset.ios27Glass => const Color(0xFFF2F5FA),
    MeowVisualPreset.obsidian => const Color(0xFFF2F4F7),
    MeowVisualPreset.sakuraAura => const Color(0xFFFAF3F6),
    MeowVisualPreset.morandiMist => const Color(0xFFF2F3F0),
  };

  Color get previewBgDark => switch (this) {
    MeowVisualPreset.crispMist => const Color(0xFF101114),
    MeowVisualPreset.ios27Glass => const Color(0xFF0E1015),
    MeowVisualPreset.obsidian => const Color(0xFF07080A),
    MeowVisualPreset.sakuraAura => const Color(0xFF141019),
    MeowVisualPreset.morandiMist => const Color(0xFF121413),
  };
}

/// 灵动动效强度三档：控制弹簧回弹与过渡节奏。
enum MeowMotionLevel {
  soft,
  standard,
  lively;

  String get label => switch (this) {
    MeowMotionLevel.soft => '柔和',
    MeowMotionLevel.standard => '标准',
    MeowMotionLevel.lively => '灵动',
  };

  double get durationScale => switch (this) {
    MeowMotionLevel.soft => 1.15,
    MeowMotionLevel.standard => 1.0,
    MeowMotionLevel.lively => 0.88,
  };

  double get bounceScale => switch (this) {
    MeowMotionLevel.soft => 0.72,
    MeowMotionLevel.standard => 1.0,
    MeowMotionLevel.lively => 1.25,
  };
}

/// 主页自适应列数模式：自动（按每张卡片的半宽/整行与屏宽智能排布）/ 强制单列 / 优先双列。
enum HomeColumnsMode {
  auto,
  single,
  doubleCol;

  String get label => switch (this) {
    HomeColumnsMode.auto => '自动',
    HomeColumnsMode.single => '单列',
    HomeColumnsMode.doubleCol => '双列',
  };
}

/// 主页卡片自适应高度档位。
enum HomeCardHeightMode {
  compact,
  standard,
  comfortable;

  String get label => switch (this) {
    HomeCardHeightMode.compact => '紧凑',
    HomeCardHeightMode.standard => '标准',
    HomeCardHeightMode.comfortable => '舒展',
  };

  double get paddingScale => switch (this) {
    HomeCardHeightMode.compact => 0.82,
    HomeCardHeightMode.standard => 1.0,
    HomeCardHeightMode.comfortable => 1.18,
  };

  double get chartHeight => switch (this) {
    HomeCardHeightMode.compact => 36,
    HomeCardHeightMode.standard => 50,
    HomeCardHeightMode.comfortable => 68,
  };
}

/// 主页布局快捷预设。
enum HomeLayoutPreset {
  classic,
  compactDual,
  minimal;

  String get label => switch (this) {
    HomeLayoutPreset.classic => '经典默认',
    HomeLayoutPreset.compactDual => '双列紧凑',
    HomeLayoutPreset.minimal => '极简模式',
  };
}

/// 主页可排序 / 可切换整行与半宽的顶级卡片模块（默认顺序严格保留原布局）。
enum HomeBlockId {
  hero,
  speed,
  subscription,
  features,
  metrics,
  exitIp;

  String get label => switch (this) {
    HomeBlockId.hero => '连接主卡',
    HomeBlockId.speed => '实时网速',
    HomeBlockId.subscription => '订阅用量',
    HomeBlockId.features => '代理应用与喵窝',
    HomeBlockId.metrics => '核心指标',
    HomeBlockId.exitIp => '出口 IP',
  };

  /// 是否允许设为半宽（连接主卡信息密度高，固定整行；其余 5 块均可自由切换整行/半宽）
  bool get canHalfWidth => this != HomeBlockId.hero;
}

@immutable
class MeowUiPrefs {
  const MeowUiPrefs({
    this.preset = MeowVisualPreset.crispMist,
    this.motionLevel = MeowMotionLevel.standard,
    this.glassFrost = 0.5,
    this.glassTinted = false,
    this.columnsMode = HomeColumnsMode.auto,
    this.heightMode = HomeCardHeightMode.standard,
    this.blockOrder = defaultBlockOrder,
    this.halfWidthBlocks = const {},
    this.hiddenBlocks = const {},
    this.showDesktopTakeover = false,
  });

  static const defaultBlockOrder = <HomeBlockId>[
    HomeBlockId.hero,
    HomeBlockId.speed,
    HomeBlockId.subscription,
    HomeBlockId.features,
    HomeBlockId.metrics,
    HomeBlockId.exitIp,
  ];

  final MeowVisualPreset preset;
  final MeowMotionLevel motionLevel;

  /// Dock 与弹出层的液态玻璃模糊与折射强度（0.0 = 极清透，1.0 = 更柔雾）
  final double glassFrost;

  /// Dock 与弹出层是否使用「着色」高对比玻璃（类似 iOS 26/27 透明 vs 着色）
  final bool glassTinted;

  final HomeColumnsMode columnsMode;
  final HomeCardHeightMode heightMode;
  final List<HomeBlockId> blockOrder;
  final Set<HomeBlockId> halfWidthBlocks;
  final Set<HomeBlockId> hiddenBlocks;

  /// 桌面端首页是否额外显示独立的「接管方式」卡片（默认关闭，侧栏底部已常驻 TUN / 系统代理开关）
  final bool showDesktopTakeover;

  bool get isIos27Glass => preset == MeowVisualPreset.ios27Glass;

  /// 识别当前是否命中某个内置布局预设（仅用于抽屉高亮）
  HomeLayoutPreset? get activeLayoutPreset {
    if (columnsMode == HomeColumnsMode.auto &&
        heightMode == HomeCardHeightMode.standard &&
        halfWidthBlocks.isEmpty &&
        hiddenBlocks.isEmpty &&
        _listEq(blockOrder, defaultBlockOrder)) {
      return HomeLayoutPreset.classic;
    }
    if (columnsMode == HomeColumnsMode.doubleCol &&
        heightMode == HomeCardHeightMode.compact &&
        hiddenBlocks.isEmpty &&
        halfWidthBlocks.contains(HomeBlockId.speed) &&
        halfWidthBlocks.contains(HomeBlockId.subscription)) {
      return HomeLayoutPreset.compactDual;
    }
    if (columnsMode == HomeColumnsMode.single &&
        hiddenBlocks.contains(HomeBlockId.features) &&
        hiddenBlocks.contains(HomeBlockId.metrics) &&
        hiddenBlocks.contains(HomeBlockId.exitIp)) {
      return HomeLayoutPreset.minimal;
    }
    return null;
  }

  MeowUiPrefs copyWith({
    MeowVisualPreset? preset,
    MeowMotionLevel? motionLevel,
    double? glassFrost,
    bool? glassTinted,
    HomeColumnsMode? columnsMode,
    HomeCardHeightMode? heightMode,
    List<HomeBlockId>? blockOrder,
    Set<HomeBlockId>? halfWidthBlocks,
    Set<HomeBlockId>? hiddenBlocks,
    bool? showDesktopTakeover,
  }) => MeowUiPrefs(
    preset: preset ?? this.preset,
    motionLevel: motionLevel ?? this.motionLevel,
    glassFrost: glassFrost ?? this.glassFrost,
    glassTinted: glassTinted ?? this.glassTinted,
    columnsMode: columnsMode ?? this.columnsMode,
    heightMode: heightMode ?? this.heightMode,
    blockOrder: blockOrder ?? this.blockOrder,
    halfWidthBlocks: halfWidthBlocks ?? this.halfWidthBlocks,
    hiddenBlocks: hiddenBlocks ?? this.hiddenBlocks,
    showDesktopTakeover: showDesktopTakeover ?? this.showDesktopTakeover,
  );

  MeowUiPrefs withLayoutPreset(HomeLayoutPreset p) => switch (p) {
    HomeLayoutPreset.classic => copyWith(
      columnsMode: HomeColumnsMode.auto,
      heightMode: HomeCardHeightMode.standard,
      blockOrder: defaultBlockOrder,
      halfWidthBlocks: const {},
      hiddenBlocks: const {},
    ),
    HomeLayoutPreset.compactDual => copyWith(
      columnsMode: HomeColumnsMode.doubleCol,
      heightMode: HomeCardHeightMode.compact,
      blockOrder: defaultBlockOrder,
      halfWidthBlocks: const {
        HomeBlockId.speed,
        HomeBlockId.subscription,
        HomeBlockId.features,
        HomeBlockId.exitIp,
      },
      hiddenBlocks: const {},
    ),
    HomeLayoutPreset.minimal => copyWith(
      columnsMode: HomeColumnsMode.single,
      heightMode: HomeCardHeightMode.standard,
      blockOrder: defaultBlockOrder,
      halfWidthBlocks: const {},
      hiddenBlocks: const {HomeBlockId.features, HomeBlockId.metrics, HomeBlockId.exitIp},
    ),
  };

  Map<String, Object?> toJson() => {
    'preset': preset.name,
    'motionLevel': motionLevel.name,
    'glassFrost': glassFrost,
    'glassTinted': glassTinted,
    'columnsMode': columnsMode.name,
    'heightMode': heightMode.name,
    'blockOrder': [for (final b in blockOrder) b.name],
    'halfWidthBlocks': [for (final b in halfWidthBlocks) b.name],
    'hiddenBlocks': [for (final b in hiddenBlocks) b.name],
    'showDesktopTakeover': showDesktopTakeover,
  };

  factory MeowUiPrefs.fromJson(Map<String, Object?> json) {
    T enumOf<T extends Enum>(List<T> values, Object? raw, T fallback) {
      if (raw is String) {
        for (final v in values) {
          if (v.name == raw) return v;
        }
      }
      return fallback;
    }

    List<HomeBlockId> parseOrder(Object? raw) {
      final result = <HomeBlockId>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is String) {
            for (final b in HomeBlockId.values) {
              if (b.name == item && !result.contains(b)) result.add(b);
            }
          }
        }
      }
      for (final b in defaultBlockOrder) {
        if (!result.contains(b)) result.add(b);
      }
      return result;
    }

    Set<HomeBlockId> parseSet(Object? raw) {
      final result = <HomeBlockId>{};
      if (raw is List) {
        for (final item in raw) {
          if (item is String) {
            for (final b in HomeBlockId.values) {
              if (b.name == item) result.add(b);
            }
          }
        }
      }
      return result;
    }

    return MeowUiPrefs(
      preset: enumOf(MeowVisualPreset.values, json['preset'], MeowVisualPreset.crispMist),
      motionLevel: enumOf(MeowMotionLevel.values, json['motionLevel'], MeowMotionLevel.standard),
      glassFrost: ((json['glassFrost'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
      glassTinted: json['glassTinted'] == true,
      columnsMode: enumOf(HomeColumnsMode.values, json['columnsMode'], HomeColumnsMode.auto),
      heightMode: enumOf(HomeCardHeightMode.values, json['heightMode'], HomeCardHeightMode.standard),
      blockOrder: parseOrder(json['blockOrder']),
      halfWidthBlocks: parseSet(json['halfWidthBlocks']),
      hiddenBlocks: parseSet(json['hiddenBlocks']),
      showDesktopTakeover: json['showDesktopTakeover'] == true,
    );
  }

  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is MeowUiPrefs &&
      other.preset == preset &&
      other.motionLevel == motionLevel &&
      other.glassFrost == glassFrost &&
      other.glassTinted == glassTinted &&
      other.columnsMode == columnsMode &&
      other.heightMode == heightMode &&
      _listEq(other.blockOrder, blockOrder) &&
      other.halfWidthBlocks.length == halfWidthBlocks.length &&
      other.halfWidthBlocks.containsAll(halfWidthBlocks) &&
      other.hiddenBlocks.length == hiddenBlocks.length &&
      other.hiddenBlocks.containsAll(hiddenBlocks) &&
      other.showDesktopTakeover == showDesktopTakeover;

  @override
  int get hashCode => Object.hash(
    preset,
    motionLevel,
    glassFrost,
    glassTinted,
    columnsMode,
    heightMode,
    Object.hashAll(blockOrder),
    Object.hashAllUnordered(halfWidthBlocks),
    Object.hashAllUnordered(hiddenBlocks),
    showDesktopTakeover,
  );
}

/// 全局静态镜像，方便非 Consumer 的底层组件（如 Dock、Dialog、Popover、Motion）零开销读取当前动效与液态玻璃参数。
abstract final class MeowUiRuntime {
  static MeowUiPrefs current = const MeowUiPrefs();
}

const _kUiPrefsKey = 'meowx_ui_prefs_v1';

class MeowUiPrefsNotifier extends Notifier<MeowUiPrefs> {
  bool _loaded = false;

  @override
  MeowUiPrefs build() {
    if (!_loaded) {
      _loaded = true;
      Future.microtask(_load);
    }
    return MeowUiRuntime.current;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUiPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final next = MeowUiPrefs.fromJson(decoded);
        MeowUiRuntime.current = next;
        state = next;
      }
    } catch (_) {
      // 忽略损坏的旧缓存，保留默认配置
    }
  }

  void update(MeowUiPrefs Function(MeowUiPrefs s) builder) {
    final next = builder(state);
    if (next == state) return;
    MeowUiRuntime.current = next;
    state = next;
    _save(next);
  }

  Future<void> _save(MeowUiPrefs value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUiPrefsKey, jsonEncode(value.toJson()));
    } catch (_) {}
  }
}

final meowUiPrefsProvider = NotifierProvider<MeowUiPrefsNotifier, MeowUiPrefs>(MeowUiPrefsNotifier.new);
