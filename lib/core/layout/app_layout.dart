import 'package:flutter/widgets.dart';

/// 共享的响应式断点，按当前窗口尺寸计算，不假设设备固定为手机竖屏。
class AppLayout {
  const AppLayout._();

  static Size sizeOf(BuildContext context) => MediaQuery.sizeOf(context);

  static bool isShortScreen(BuildContext context) =>
      sizeOf(context).height < 600;

  static bool usesLargeText(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1) > 1.25;

  /// 竖屏继续使用原有紧凑弹窗；横屏或短窗口给扫描结果留出空间。
  static double connectionSheetHeightFactor(BuildContext context) =>
      isShortScreen(context) ? .88 : .55;

  static double connectionAnimationSize(BuildContext context) =>
      sizeOf(context).height < 500 ? 72 : 112;
}
