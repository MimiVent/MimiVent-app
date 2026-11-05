import 'package:flutter/material.dart';

/// MimiVent 页面与状态组件统一使用的语义颜色。
class MimiVentColors {
  const MimiVentColors._();

  static const page = Color(0xFF08110F);
  static const surface = Color(0xFF13231F);
  static const surfaceRaised = Color(0xFF1A2D28);
  static const mint = Color(0xFF9BE8CC);
  static const muted = Color(0xFFA7B8B1);
  static const amber = Color(0xFFFFCB79);
  static const red = Color(0xFFF17B79);
  static const darkText = Color(0xFF10201B);

  static const pageGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF14231F), Color(0xFF0B1513), page],
    stops: [0, .48, 1],
  );
}

/// 页面主背景、卡片与状态色的主题扩展，集中维护 MimiVent 的视觉令牌。
@immutable
class MimiVentTheme extends ThemeExtension<MimiVentTheme> {
  const MimiVentTheme({
    required this.pageBackground,
    required this.surface,
    required this.surfaceRaised,
    required this.mint,
    required this.muted,
    required this.amber,
    required this.danger,
  });

  final LinearGradient pageBackground;
  final Color surface;
  final Color surfaceRaised;
  final Color mint;
  final Color muted;
  final Color amber;
  final Color danger;

  static MimiVentTheme of(BuildContext context) =>
      Theme.of(context).extension<MimiVentTheme>()!;

  @override
  MimiVentTheme copyWith({
    LinearGradient? pageBackground,
    Color? surface,
    Color? surfaceRaised,
    Color? mint,
    Color? muted,
    Color? amber,
    Color? danger,
  }) =>
      MimiVentTheme(
        pageBackground: pageBackground ?? this.pageBackground,
        surface: surface ?? this.surface,
        surfaceRaised: surfaceRaised ?? this.surfaceRaised,
        mint: mint ?? this.mint,
        muted: muted ?? this.muted,
        amber: amber ?? this.amber,
        danger: danger ?? this.danger,
      );

  @override
  MimiVentTheme lerp(ThemeExtension<MimiVentTheme>? other, double t) {
    if (other is! MimiVentTheme) return this;
    return MimiVentTheme(
      pageBackground:
          LinearGradient.lerp(pageBackground, other.pageBackground, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      mint: Color.lerp(mint, other.mint, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// 共享动画时长，便于跨页面统一调整动效节奏。
class MimiVentMotion {
  const MimiVentMotion._();

  static const fanStart = Duration(milliseconds: 1800);
  static const fanStop = Duration(milliseconds: 1600);
  static const logoPulse = Duration(milliseconds: 1700);
  static const bluetoothPulse = Duration(milliseconds: 1900);
}

ThemeData buildMimiVentTheme() {
  return ThemeData(
    useMaterial3: true,
    // InkSparkle 在 Flutter 3.22 的软件渲染路径（测试环境、无 GPU 的低端设备）
    // 会在 paint 阶段抛 RangeError，进而让 State 生命周期异常收尾，
    // 表现为 "_debugLifecycleState == _StateLifecycle.ready" 断言。
    // 固定为经典波纹（InkRipple），避开这条会崩的分支。
    splashFactory: InkRipple.splashFactory,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: MimiVentColors.page,
    colorScheme: ColorScheme.fromSeed(
      seedColor: MimiVentColors.mint,
      brightness: Brightness.dark,
      surface: MimiVentColors.surface,
    ),
    fontFamily: 'Roboto',
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Color(0xFFE5F7EF),
      contentTextStyle:
          TextStyle(color: Color(0xFF10231D), fontWeight: FontWeight.w600),
    ),
    extensions: const [
      MimiVentTheme(
        pageBackground: MimiVentColors.pageGradient,
        surface: MimiVentColors.surface,
        surfaceRaised: MimiVentColors.surfaceRaised,
        mint: MimiVentColors.mint,
        muted: MimiVentColors.muted,
        amber: MimiVentColors.amber,
        danger: MimiVentColors.red,
      ),
    ],
  );
}
